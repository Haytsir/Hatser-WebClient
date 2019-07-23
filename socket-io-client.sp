/* We like semicolons */
#pragma semicolon 1

#include <sourcemod>
#include <socket>
#include "include/websocket-client.inc"
#include "include/socket-io-client.inc"
#include "include/EasyJSON.inc"

Handle g_hSocket = null;
Handle g_hForwardReceiveData = null;

bool g_bHandshaked = false;
bool g_bConnected = false;

public Plugin myinfo = 
{
	name = "[BST] Socket.io - Client",
	author = "Trostal",
	description = "Interacts with the web server via Socket.io",
	version = "1.3.0",
	url = ""
};

public void OnPluginStart(){
	// SocketIOClient_OnReceiveData (Handle socket, EngineIOPacketType iEIOPType, SocketIOPacketType iSIOPType, const char[] sEventName, ArrayList hDataArray);
	g_hForwardReceiveData = CreateGlobalForward("SocketIOClient_OnReceiveData", ET_Ignore, Param_Cell, Param_Cell, Param_Cell, Param_String, Param_Cell);
}

public void OnAllPluginsLoaded()
{
	if(LibraryExists("websocket-client")) {		
		Handle hSocket = SocketCreate(SOCKET_TCP, OnSocketError);
		SocketConnect(hSocket, OnSocketConnected, OnSocketReceived, OnSocketDisconnected, "127.0.0.1", 80);
		WebsocketClient_UseWebsocketInterface(hSocket, OnSocketReceivePlain, OnSocketReceive);
		g_hSocket = hSocket;
	} else {
		CreateTimer(10.0, Retry);
	}
}

public void OnPluginEnd() {

}

public Action Retry(Handle timer) {
	if(g_hSocket == null && !g_bHandshaked)
		OnAllPluginsLoaded();
}

public Action CheckHandshaked(Handle timer, Handle socket) {
	if(!g_bHandshaked && g_bConnected && SocketIsConnected(socket)) {
		SocketDisconnect(socket);
		g_bConnected = false;
	}
}

public OnSocketConnected(Handle socket, any arg) {
	// socket is connected, send the http request
	PrintToServer("######Socket Connected!######");
	char requestStr[512];
	g_bHandshaked = false;
	g_bConnected = true;
	// 핸드쉐이크 시도 시작, 소켓에 최초 접근 시도.
	char sYeast[8];
	
	CreateTimer(10.0, CheckHandshaked, socket);
	
	yeast(sYeast);
	Format(requestStr, sizeof(requestStr), "GET /%s%s HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade\r\nUpgrade: WebSocket\r\nOrigin: http://127.0.0.1:80/\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: %s\r\n\r\n", "socket.io/?EIO=3&clienttype=SRCDS&transport=websocket&t=", sYeast, "127.0.0.1:80", "YW4gc3JjZHMgd3MgdGVzdA==");
//	Format(requestStr, sizeof(requestStr), "GET /%s%s HTTP/1.1\r\nHost: %s\r\n\r\n", "socket.io/?clienttype=SRCDS&EIO=3&transport=polling&t=", sYeast, "127.0.0.1:3000");
	//	Format(requestStr, sizeof(requestStr), "GET /%s%s HTTP/1.1\r\nHost: %s\r\n\r\n", "primus/info?_primuscb=M2K5XBQ&t=", "1514312962787"/*yeast*/, "localhost");
	SocketSend(socket, requestStr);
}

public OnSocketError(Handle socket, const int errorType, const int errorNum, any:arg) {
	// a socket error occured

	LogError("socket error %d (errno %d)", errorType, errorNum);
	WebsocketClient_UnuseWebsocketInterface(socket);
	if(g_bConnected && SocketIsConnected(socket)) {
		SocketDisconnect(socket);
	}
	CloseHandle(socket);
	socket = null;
	g_bConnected = false;
	g_bHandshaked = false;
	g_hSocket = null;
	CreateTimer(10.0, Retry);
}

public OnSocketDisconnected(Handle socket, any hFile) {
	PrintToServer("The socket disconnected from server!");
	WebsocketClient_UnuseWebsocketInterface(socket);
	CloseHandle(socket);
	socket = null;
	
	g_bHandshaked = false;
	g_bConnected = false;
	g_hSocket = null;
	CreateTimer(10.0, Retry);
}

public OnSocketReceived(Handle socket, char[] receiveData, const int dataSize, any:hFile){}
public Action OnSocketReceivePlain(Handle socket, char[] receiveData, const int dataSize, any:hFile)
{
	if(!g_bHandshaked) {
		if(StrContains(receiveData, "HTTP/1.1 101 Switching Protocols", true) == 0)
		{
		    /*
			HTTP/1.1 101 Switching Protocols
			Upgrade: websocket
			Connection: Upgrade
			Sec-WebSocket-Accept: MWRJjQKH/LfNpV4m0z+2rF8En+k=
			Sec-WebSocket-Protocol: chat
			*/
			PrintToServer("[WebSocketClient] Handshaked!");
			g_bHandshaked = true;
		}
		return Plugin_Handled;
	} else {
		return Plugin_Continue;
	}
	
}

public void OnSocketReceive(Handle socket, WebsocketSendType iType, const char[] sPayload, const int dataSize) {
	
	int iArrayBracketPos = FindCharInString(sPayload, '[', false);
	int iObjectBracketPos = FindCharInString(sPayload, '{', false);
	
	int iOpeningPos;
	if(iArrayBracketPos == -1 && iObjectBracketPos == -1) {
		return;
	} else if(iArrayBracketPos >= 0 && iObjectBracketPos == -1) {
		iOpeningPos = iArrayBracketPos;
	} else if(iArrayBracketPos == -1 && iObjectBracketPos >= 0) {
		iOpeningPos = iObjectBracketPos;
	} else {
		if(iArrayBracketPos > iObjectBracketPos) {
			iOpeningPos = iObjectBracketPos;
		} else {
			iOpeningPos = iArrayBracketPos;
		}
	}
	
	EngineIOPacketType iEIP;
	SocketIOPacketType iSIP;
	
	char[] sPayloadData = new char[dataSize];
	// 원래 데이터의 +1 만큼 공간을 줘서 마지막 \0 값이 들어가도록 해주는게 맞으나,
	// 페이로드 앞의 패킷타입 문자를 제하고 넣을 것이므로... [결국: +2-1 = -1]
	strcopy(sPayloadData, dataSize-1, sPayload[iOpeningPos]);
	
	if(IsCharNumeric(sPayload[0])) {
		// 아스키코드 숫자 0의 값이 48이다.
		iEIP = view_as<EngineIOPacketType>(sPayload[0]) - 48;
	}
	if(IsCharNumeric(sPayload[1])) {
		iSIP = view_as<SocketIOPacketType>(sPayload[1]) - 48;
	}
	
	ArrayList PayloadArrayObject = view_as<ArrayList>(DecodeArray(sPayloadData));
	
	char sEventName[32];
	if(PayloadArrayObject != null) {
		JSONGetArrayString(PayloadArrayObject, 0, sEventName, sizeof(sEventName));
		PayloadArrayObject.Erase(0);
	}
	if(StrEqual(sEventName, "ping", true)) {
		Format(sPayloadData, strlen(sPayload)+1, "%i%i[\"pong\"]", iEIP, iSIP, GetTime());
		WebsocketClient_Send(socket, SendType_Text, sPayloadData, strlen(sPayloadData));
	}
	
	Call_StartForward(g_hForwardReceiveData);
	Call_PushCell(socket);
	Call_PushCell(iEIP);
	Call_PushCell(iSIP);
	Call_PushString(sEventName);
	Call_PushCell(PayloadArrayObject);
	Call_Finish();
	
	if(PayloadArrayObject != null) {
		DestroyJSONArray(PayloadArrayObject);
	}
}

int g_iAlphabet[] = {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '-', '_'};
int g_iSeed = 0;
char g_sPrev[8];

stock yeast(char[] output) {

	char sNow[8];
	char encoded[8];
	encode(GetTime(), sNow);

	if (!StrEqual(sNow, g_sPrev)){
		g_sPrev = sNow;
		g_iSeed = 0;
	}
	
	encode(g_iSeed++, encoded);
	Format(output, 8, "%s.%s", sNow, encoded);
}

stock encode(int num, char[] encoded) {
	do {
		Format(encoded, 8, "%c%s", g_iAlphabet[num % sizeof(g_iAlphabet)], encoded);
		num = num / (sizeof(g_iAlphabet) / 4);
	} while (num > 0);
}