#include <sourcemod>
#include <socket.inc>


#include "websocket-client.inc"

public Plugin myinfo = 
{
	name = "Web Socket Interface - Client",
	author = "Peace-Maker, Trostal",
	description = "Interacts with the web server via Socket.io",
	version = "1.0",
	url = ""
};

/**
 * 틀: <ep><sp><기존페이로드데이터>
 * ex) 42["sendchat", "Hello!"]
 * <ep>: engine.io에서 패킷 타입을 나타내기 위해 넘버링 한 것
 * 0 open
 * 1 close
 * 2 ping
 * 3 pong
 * 4 message
 * 5 upgrade
 * 6 noop
 *
 * <sp>: socket.io에서 패킷 타입을 나타내기 위해 넘버링 한 것
 * Packet#CONNECT (0)
 * Packet#DISCONNECT (1)
 * Packet#EVENT (2)
 * Packet#ACK (3)
 * Packet#ERROR (4)
 * Packet#BINARY_EVENT (5)
 * Packet#BINARY_ACK (6)
 *
 */

ArrayList g_arrSockets;
ArrayList g_arrFragmentedPayloadArray;
ArrayList g_arrForwardReceiveDataPlain;
ArrayList g_arrForwardReceiveData;
ArrayList g_arrForwardCallbacks;

#define DEBUG 0
#define FRAGMENT_MAX_LENGTH 32768

enum WebsocketFrameType {
	FrameType_Continuation = 0,
	FrameType_Text = 1,
	FrameType_Binary = 2,
	FrameType_Close = 8,
	FrameType_Ping = 9,
	FrameType_Pong = 10
}

enum WebsocketFrame
{
	FIN,
	RSV1,
	RSV2,
	RSV3,
	WebsocketFrameType:OPCODE,
	MASK,
	PAYLOAD_LEN,
	String:MASKINGKEY[5],
	CLOSE_REASON
}

public void OnPluginStart() {	
	g_arrSockets = new ArrayList();
	g_arrFragmentedPayloadArray = new ArrayList();
	g_arrForwardReceiveDataPlain = new ArrayList();
	g_arrForwardReceiveData = new ArrayList();
	g_arrForwardCallbacks = new ArrayList();
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("WebsocketClient_UseWebsocketInterface", Native_WebsocketClient_UseWebsocketInterface);
	CreateNative("WebsocketClient_Send", Native_WebsocketClient_Send);
	CreateNative("WebsocketClient_UnuseWebsocketInterface", Native_WebsocketClient_UnuseWebsocketInterface);
	RegPluginLibrary("websocket-client");
	return APLRes_Success;
}

//WebSocetClient_UseWebsocketInterface(Handle socket, recvPlainCB, recvCB)
public int Native_WebsocketClient_UseWebsocketInterface(Handle plugin, int numParams)
{
	Handle hSocket = view_as<Handle>GetNativeCell(1);
	g_arrSockets.Push(hSocket);
	
	Handle hForwardReceiveDataPlain = CreateForward(ET_Hook, Param_Cell, Param_String, Param_Cell, Param_Any);
	Handle hForwardReceiveData = CreateForward(ET_Ignore, Param_Cell, Param_Cell, Param_String, Param_Cell);
	
	SocketSetReceiveCallback(hSocket, OnSocketReceive);
	
	g_arrForwardReceiveDataPlain.Push(hForwardReceiveDataPlain);
	g_arrForwardReceiveData.Push(hForwardReceiveData);
	
	DataPack hPack = new DataPack();
	hPack.WriteFunction(GetNativeFunction(2));
	hPack.WriteFunction(GetNativeFunction(3));
	
	g_arrForwardCallbacks.Push(hPack);
	
	if(!AddToForward(hForwardReceiveDataPlain, plugin, GetNativeFunction(2))){
		LogError("Unable to add plugin to receive plain data callback");
		return false;
	}
	if(!AddToForward(hForwardReceiveData, plugin, GetNativeFunction(3))){
		LogError("Unable to add plugin to receive data callback");
		return false;
	}
	
	Handle hFragmentedPayload = CreateArray(ByteCountToCells(FRAGMENT_MAX_LENGTH));
	PushArrayCell(hFragmentedPayload, 0); // The first element will always be the payload length.
	PushArrayCell(hFragmentedPayload, 0); // The second element is the payload type. (Even though we don't handle text and binary differently..)
	
	g_arrFragmentedPayloadArray.Push(hFragmentedPayload);	
	
	return true;
}

public int Native_WebsocketClient_UnuseWebsocketInterface(Handle plugin, int numParams)
{
	Handle hSocket = view_as<Handle>GetNativeCell(1);
	
	int iIndex = g_arrSockets.FindValue(hSocket);
	
	Handle hForwardReceiveDataPlain = g_arrForwardReceiveDataPlain.Get(iIndex);
	Handle hForwardReceiveData = g_arrForwardReceiveData.Get(iIndex);
	ArrayList hFragmentedPayloadArray = view_as<ArrayList>(g_arrFragmentedPayloadArray.Get(iIndex));
	
	SocketSetReceiveCallback(hSocket, OnSocketReceive);	
	
	DataPack hPack = g_arrForwardCallbacks.Get(iIndex);
	hPack.Reset();
	
	RemoveFromForward(hForwardReceiveDataPlain, plugin, hPack.ReadFunction());
	RemoveFromForward(hForwardReceiveData, plugin, hPack.ReadFunction());
	
	delete hPack;
	delete hFragmentedPayloadArray;
	delete hForwardReceiveDataPlain;
	delete hForwardReceiveData;

	g_arrSockets.Erase(iIndex);
	g_arrFragmentedPayloadArray.Erase(iIndex);
	g_arrForwardReceiveDataPlain.Erase(iIndex);
	g_arrForwardReceiveData.Erase(iIndex);
	g_arrForwardCallbacks.Erase(iIndex);
	
	return true;
}

public OnSocketReceive(Handle socket, char[] receiveData, const int dataSize, any:hFile)
{
	int iIndex = g_arrSockets.FindValue(socket);
	Handle hForwardReceiveDataPlain = view_as<Handle>(g_arrForwardReceiveDataPlain.Get(iIndex));
	Action ret = Plugin_Continue;
	
	Call_StartForward(hForwardReceiveDataPlain);
	Call_PushCell(socket);
	Call_PushString(receiveData);
	Call_PushCell(dataSize);
	Call_PushCell(hFile);
	Call_Finish(ret);
	
	if (ret == Plugin_Continue)
	{
		int vFrame[WebsocketFrame]
		char[] sPayLoad = new char[dataSize-1];
		ParseFrame(vFrame, receiveData, dataSize, sPayLoad);
		if(!PreprocessFrame(iIndex, vFrame, sPayLoad))
		{
			Handle hForwardReceiveData = view_as<Handle>(g_arrForwardReceiveData.Get(iIndex));
			Call_StartForward(hForwardReceiveData);
			Call_PushCell(socket);
			
			// 분할된 메세지일 때
			if(vFrame[OPCODE] == FrameType_Continuation)
			{
				ArrayList hFragmentedPayload = view_as<ArrayList>(g_arrFragmentedPayloadArray.Get(iIndex));
				
				int iPayloadLength = GetArrayCell(hFragmentedPayload, 0);
				
				char[] sConcatPayload = new char[iPayloadLength];
				char sPayloadPart[FRAGMENT_MAX_LENGTH];
				
				int iSize = GetArraySize(hFragmentedPayload);
				// Concat all the payload parts
				// TODO: Make this binary safe? GetArrayArray vs. GetArrayString?
				for(new i=2;i<iSize;i++)
				{
					GetArrayString(hFragmentedPayload, i, sPayloadPart, sizeof(sPayloadPart));
					Format(sConcatPayload, iPayloadLength, "%s%s", sConcatPayload, sPayloadPart);
				}
				
				WebsocketSendType iType;
				if(view_as<WebsocketFrameType>(GetArrayCell(hFragmentedPayload, 1)) == FrameType_Text)
					iType = SendType_Text;
				else
					iType = SendType_Binary;
				
				Call_PushCell(iType);
				Call_PushString(sConcatPayload);
				Call_PushCell(iPayloadLength);
				
				// Clear the fragment buffer
				ClearArray(hFragmentedPayload);
				PushArrayCell(hFragmentedPayload, 0); // length
				PushArrayCell(hFragmentedPayload, 0); // opcode
			}
			// 분할되지 않은 메세지일 때
			else
			{
				WebsocketSendType iType;
				if(vFrame[OPCODE] == FrameType_Text)
					iType = SendType_Text;
				else
					iType = SendType_Binary;
				
				Call_PushCell(iType);
				Call_PushString(sPayLoad);
				Call_PushCell(vFrame[PAYLOAD_LEN]);
			}
			
			Call_Finish();
		}
	}
}

/**************************************
 * 데이터 송신시 사용하는 함수들
 **************************************/
public int Native_WebsocketClient_Send(Handle plugin, int numParams)
{	
	Handle socket = GetNativeCell(1);
	
	if(socket == null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid websocket handle.");
		return false;
	}
	
	int vFrame[WebsocketFrame];
	vFrame[OPCODE] = view_as<WebsocketSendType>(GetNativeCell(2)) == SendType_Text?FrameType_Text:FrameType_Binary;
	
	vFrame[PAYLOAD_LEN] = GetNativeCell(4);
	if(vFrame[PAYLOAD_LEN] == -1)
		GetNativeStringLength(3, vFrame[PAYLOAD_LEN]);
		
	
	char[] sPayLoad = new char[vFrame[PAYLOAD_LEN]+1];	
	GetNativeString(3, sPayLoad, vFrame[PAYLOAD_LEN]+1);
	
	vFrame[FIN] = 1;
	vFrame[CLOSE_REASON] = -1;
	vFrame[MASK] = 1;
	SendWebsocketFrame(socket, sPayLoad, vFrame);
	
	return true;
}

bool SendWebsocketFrame(Handle s, char[] sPayLoad, vFrame[WebsocketFrame])
{	
	int length = vFrame[PAYLOAD_LEN];
	
	Debug(1, "Preparing to send payload %s (%d)", sPayLoad, length);
	
	// Force RSV bits to 0
	vFrame[RSV1] = 0;
	vFrame[RSV2] = 0;
	vFrame[RSV3] = 0;
	
	char[] sFrame = new char[length+18];
	if(CreateFrame(sPayLoad, sFrame, vFrame))
	{
		if(length > 65535)
			length += 10;
		else if(length > 125)
			length += 4;
		else
			length += 2;
		if(vFrame[CLOSE_REASON] != -1)
			length += 2;
		Debug(1, "Sending: \"%s\"", sFrame);
		Debug(2, "FIN: %i", sFrame[0]&0x80?1:0);
		Debug(2, "RSV1: %i", sFrame[0]&0x40?1:0);
		Debug(2, "RSV2: %i", sFrame[0]&0x20?1:0);
		Debug(2, "RSV3: %i", sFrame[0]&0x10?1:0);
		Debug(2, "OPCODE: %i", _:sFrame[0]&0xf?1:0);
		Debug(2, "MASK: %i", sFrame[1]&0x80?1:0);
		Debug(2, "PAYLOAD_LEN: %i", sFrame[1]&0x7f);
		Debug(2, "PAYLOAD: %s", sPayLoad);
		Debug(2, "CLOSE_REASON: %i", vFrame[CLOSE_REASON]);
		Debug(2, "Frame: %s", sFrame);
		SocketSend(s, sFrame);
		return true;
	}
	
	return false;
}

// 프레임을 생성하자,
// sPayLoad = 붙일 페이로드
// sFrame = 생성할 프레임
// vFrame = 참고프레임
bool CreateFrame(char[] sPayLoad, char[] sFrame, vFrame[WebsocketFrame]) {
	
	int length = vFrame[PAYLOAD_LEN];
	
	switch(vFrame[OPCODE])
	{
		case FrameType_Text:
		{
			sFrame[0] = (1<<0)|(1<<7); //  - Text-Frame (1000 0001):
		}
		case FrameType_Close:
		{
			sFrame[0] = (1<<3)|(1<<7); //  -  Close-Frame (1000 1000):
			length += 2; // Remember the 2byte close reason
		}
		case FrameType_Ping:
		{
			sFrame[0] = (1<<0)|(1<<3)|(1<<7); //  -  Ping-Frame (1000 1001):
		}
		case FrameType_Pong:
		{
			sFrame[0] = (1<<1)|(1<<3)|(1<<7); //  -  Pong-Frame (1000 1010):
		}
		default:
		{
			LogError("Trying to send frame with unknown opcode = %d", view_as<int>(vFrame[OPCODE]));
			return false;
		}
	}
	
	int iOffset;
	
	// 길이 "바이트" (7bit)를 추가한다. 클라이언트는 항상 마스크된 메세지만 보내야 한다
	if(length > 65535)
	{
		sFrame[1] = 128;
		char sLengthBin[65], sByte[9];
		Format(sLengthBin, 65, "%064b", length);
		for(new i=0,j=2;j<=10;i++)
		{
			if(i && !(i%8))
			{
				sFrame[j] = bindec(sByte);
				Format(sByte, 9, "");
				j++;
			}
			Format(sByte, 9, "%s%s", sByte, sLengthBin[i]);
		}
		
		// the most significant bit MUST be 0
		if(sFrame[2] > 127)
		{
			LogError("Can't send frame. Too much data.");
			return false;
		}
		iOffset = 9;
	}
	else if(length > 125)
	{
		sFrame[1] = 254; // 126, 뒤따라올 EXTENDED_PAYLOAD_LEN의 길이를 나타내는 플래그 역할
		if(length < 256)
		{
			sFrame[2] = 0;
			sFrame[3] = length;
		}
		else
		{
			char sLengthBin[17], sByte[9];
			Format(sLengthBin, 17, "%016b", length);
			for(new i=0,j=2;i<=16;i++)
			{
				if(i && !(i%8))
				{
					sFrame[j] = bindec(sByte);
					Format(sByte, 9, "");
					j++;
				}
				Format(sByte, 9, "%s%s", sByte, sLengthBin[i]);
			}
		}
		iOffset = 4;
	}
	else
	{
		sFrame[1] = length; // sFrame[1] 이 필드 자체가 PayloadData의 실제 길이를 나타낸다
		iOffset = 2;
	}
	
	// 마스크 비트를 확실하게 1로 둔다
	sFrame[1] |= (1<<7);
	
	int iMaskingKey[4];
	iMaskingKey[0] = 255; //GetRandomInt(0, 255);
	iMaskingKey[1] = 254; //GetRandomInt(0, 255);
	iMaskingKey[2] = 253; //GetRandomInt(0, 255);
	iMaskingKey[3] = 252; //GetRandomInt(0, 255);
	
	sFrame[iOffset] = iMaskingKey[0];
	sFrame[iOffset+1] = iMaskingKey[1];
	sFrame[iOffset+2] = iMaskingKey[2];
	sFrame[iOffset+3] = iMaskingKey[3];
	iOffset += 4;
	length += 4;
	
	// We got a closing reason. Add it right in front of the payload.
	if(vFrame[OPCODE] == FrameType_Close && vFrame[CLOSE_REASON] != -1)
	{
		char sCloseReasonBin[17], sByte[9];
		Format(sCloseReasonBin, 17, "%016b", vFrame[CLOSE_REASON]);
		for(new i=0,j=iOffset;i<=16;i++)
		{
			if(i && !(i%8))
			{
				sFrame[j] = bindec(sByte);
				Format(sByte, 9, "");
				j++;
			}
			Format(sByte, 9, "%s%s", sByte, sCloseReasonBin[i]);
		}
		iOffset += 2;
	}
	
	// 마스킹 과정
	char[] masked = new char[vFrame[PAYLOAD_LEN] + 1];
	for(new i=0;i<vFrame[PAYLOAD_LEN];i++)
	{
		Format(masked, vFrame[PAYLOAD_LEN] + 1, "%s%c", masked, (sPayLoad[i]&0xff)^iMaskingKey[i%4]);
	}
	
	// 마지막에 페이로드 데이터를 붙여준다
	strcopy(sFrame[iOffset], length+iOffset, masked);
	
	return true;
}

/**************************************
 * 데이터 수신시 사용하는 함수들
 **************************************/

ParseFrame(int vFrame[WebsocketFrame], const char[] receiveDataLong, const int dataSize, char[] sPayLoad)
{
	// We're only interested in the first 8 bits.. what's that rest?!
	int[] receiveData = new int[dataSize];
	for(new i=0;i<dataSize;i++)
	{
		receiveData[i] = receiveDataLong[i]&0xff;
		Debug(3, "%d (%c): %08b", i, (receiveData[i]<32?' ':receiveData[i]), receiveData[i]);
	}
	
	char sByte[9];
	Format(sByte, sizeof(sByte), "%08b", receiveData[0]);
	Debug(3, "First byte: %s", sByte);
	vFrame[FIN] = sByte[0]=='1'?1:0;
	vFrame[RSV1] = sByte[1]=='1'?1:0;
	vFrame[RSV2] = sByte[2]=='1'?1:0;
	vFrame[RSV3] = sByte[3]=='1'?1:0;
	vFrame[OPCODE] = view_as<WebsocketFrameType>(bindec(sByte[4]));
	
	Format(sByte, sizeof(sByte), "%08b", receiveData[1]);
	Debug(3, "Second byte: %s", sByte);
	vFrame[MASK] = sByte[0]=='1'?1:0;
	vFrame[PAYLOAD_LEN] = bindec(sByte[1]);
	
	int iOffset = 2;
	
	vFrame[MASKINGKEY][0] = '\0';
	if(vFrame[PAYLOAD_LEN] > 126)
	{
		char sLoongLength[49];
		for(new i=2;i<8;i++)
			Format(sLoongLength, sizeof(sLoongLength), "%s%08b", sLoongLength, receiveData[i]);
		
		vFrame[PAYLOAD_LEN] = bindec(sLoongLength);
		iOffset += 6;
	}
	else if(vFrame[PAYLOAD_LEN] > 125)
	{
		char sLongLength[17];
		for(new i=2;i<4;i++)
			Format(sLongLength, sizeof(sLongLength), "%s%08b", sLongLength, receiveData[i]);
		
		vFrame[PAYLOAD_LEN] = bindec(sLongLength);
		iOffset += 2;
	}
	// 마스크 되어있다면 마스크를 해제한다.
	// 하지만 페이로드를 마스킹하는 것은 클라이언트 뿐이므로,
	// 서버로부터 받은 데이터는 절대 마스크된 상태여서는 안된다. (절대 실행되지 말아야 할 분기문...)
	if(vFrame[MASK])
	{
		for(new i=iOffset,j=0;j<4;i++,j++)
			vFrame[MASKINGKEY][j] = receiveData[i];
		vFrame[MASKINGKEY][4] = '\0';
		iOffset += 4;
		
		int[] iPayLoad = new int[vFrame[PAYLOAD_LEN]];
		for(new i=iOffset,j=0;j<vFrame[PAYLOAD_LEN];i++,j++)
			iPayLoad[j] = receiveData[i];
			
		for(new i=0;i<vFrame[PAYLOAD_LEN];i++)
		{
			Format(sPayLoad, vFrame[PAYLOAD_LEN]+1, "%s%c", sPayLoad, iPayLoad[i]^vFrame[MASKINGKEY][i%4]);
		}
	}
	
	strcopy(sPayLoad, vFrame[PAYLOAD_LEN]+1, receiveDataLong[iOffset]);
	
	Debug(2, "dataSize: %d", dataSize);
	Debug(2, "FIN: %d", vFrame[FIN]);
	Debug(2, "RSV1: %d", vFrame[RSV1]);
	Debug(2, "RSV2: %d", vFrame[RSV2]);
	Debug(2, "RSV3: %d", vFrame[RSV3]);
	Debug(2, "OPCODE: %d", _:vFrame[OPCODE]);
	Debug(2, "MASK: %d", vFrame[MASK]);
	Debug(2, "PAYLOAD_LEN: %d", vFrame[PAYLOAD_LEN]);
	
	// Client requested connection close
	if(vFrame[OPCODE] == FrameType_Close)
	{
		// first 2 bytes are close reason
		char sCloseReason[65];
		for(new i=0;i<2;i++)
			Format(sCloseReason, sizeof(sCloseReason), "%s%08b", sCloseReason, sPayLoad[i]&0xff);
		
		vFrame[CLOSE_REASON] = bindec(sCloseReason);
		
		strcopy(sPayLoad, dataSize-1, sPayLoad[2]);
		vFrame[PAYLOAD_LEN] -= 2;
		
		Debug(2, "CLOSE_REASON: %d", vFrame[CLOSE_REASON]);
	}
	else
	{
		vFrame[CLOSE_REASON] = -1;
	}
	
	Debug(2, "PAYLOAD: %s", sPayLoad);
	
	// TODO: utf8_decode
}

bool PreprocessFrame(int iIndex, vFrame[WebsocketFrame], char[] sPayLoad)
{
	ArrayList hFragmentedPayload = view_as<ArrayList>g_arrFragmentedPayloadArray.Get(iIndex);
	
	// This is a fragmented frame
	if(vFrame[FIN] == 0)
	{
		// This is a control frame. Those cannot be fragmented!
		if(vFrame[OPCODE] >= FrameType_Close)
		{
			LogError("Received fragmented control frame. %d", vFrame[OPCODE]);
		//	CloseConnection(s, 1002, "Received fragmented control frame.");
			return true;
		}
		
		int iPayloadLength = hFragmentedPayload.Get(0);
		
		// This is the first frame of a serie of fragmented ones.
		if(iPayloadLength == 0)
		{
			if(vFrame[OPCODE] == FrameType_Continuation)
			{
				LogError("Received first fragmented frame with opcode 0. The first fragment MUST have a different opcode set.");
			//	CloseConnection(s, 1002, "Received first fragmented frame with opcode 0. The first fragment MUST have a different opcode set.");
				return true;
			}
			
			// Remember which type of message this fragmented one is.
			hFragmentedPayload.Set(1, vFrame[OPCODE]);
		}
		else
		{
			if(vFrame[OPCODE] != FrameType_Continuation)
			{
				LogError("Received second or later frame of fragmented message with opcode %d. opcode must be 0.", vFrame[OPCODE]);
			//	CloseConnection(s, 1002, "Received second or later frame of fragmented message with opcode other than 0. opcode must be 0.");
				return true;
			}
		}
		
		// Keep track of the overall payload length of the fragmented message.
		// This is used to create the buffer of the right size when passing it to the listening plugin.
		iPayloadLength += vFrame[PAYLOAD_LEN];
		hFragmentedPayload.Set(0, iPayloadLength);
		
		// This doesn't fit inside one array cell? Split it up.
		if(vFrame[PAYLOAD_LEN] > FRAGMENT_MAX_LENGTH)
		{
			for(new i=0;i<vFrame[PAYLOAD_LEN];i+=FRAGMENT_MAX_LENGTH)
			{
				hFragmentedPayload.PushString(sPayLoad[i]);
			}
		}
		else
		{
			hFragmentedPayload.PushString(sPayLoad);
		}
		
		return true;
	}
	
	/* Commented by Peace-Maker
	if(vFrame[RSV1] != 0 || vFrame[RSV2] != 0 || vFrame[RSV3] != 0)
	{
		LogError("One of the reservation bits is set. We don't support any extensions! (rsv1: %d rsv2: %d rsv3: %d)", vFrame[RSV1], vFrame[RSV2], vFrame[RSV3]);
		CloseConnection(s, 1003, "One of the reservation bits is set.");
		return false;
	}*/
	
	// The FIN bit is set if we reach here.
	switch(vFrame[OPCODE])
	{
		case FrameType_Continuation:
		{
			int iPayloadLength = hFragmentedPayload.Get(0);
			WebsocketFrameType iOpcode = view_as<WebsocketFrameType>(hFragmentedPayload.Get(1));
			// We don't know what type of data that is.
			if(iOpcode == FrameType_Continuation)
			{
				LogError("Received last frame of a series of fragmented ones without any fragments with payload first.");
			//	CloseConnection(s, 1002, "Received last frame of fragmented message without any fragments beforehand.");
				return true;
			}
			
			// Add the payload of the last frame to the buffer too.
			
			// Keep track of the overall payload length of the fragmented message.
			// This is used to create the buffer of the right size when passing it to the listening plugin.
			iPayloadLength += vFrame[PAYLOAD_LEN];
			hFragmentedPayload.Set(0, iPayloadLength);
			
			// This doesn't fit inside one array cell? Split it up.
			if(vFrame[PAYLOAD_LEN] > FRAGMENT_MAX_LENGTH)
			{
				for(new i=0;i<vFrame[PAYLOAD_LEN];i+=FRAGMENT_MAX_LENGTH)
				{
					hFragmentedPayload.PushString(sPayLoad[i]);
				}
			}
			else
			{
				hFragmentedPayload.PushString(sPayLoad);
			}
			
			return false;
		}
		case FrameType_Text:
		{
			return false;
		}
		case FrameType_Binary:
		{
			return false;
		}
		case FrameType_Close:
		{
			// Just mirror it back
			SendWebsocketFrame(view_as<Handle>g_arrSockets.Get(iIndex), sPayLoad, vFrame);
			
			return true;
		}
		case FrameType_Ping:
		{
			vFrame[OPCODE] = FrameType_Pong;
			SendWebsocketFrame(view_as<Handle>g_arrSockets.Get(iIndex), sPayLoad, vFrame);
			return true;
		}
		case FrameType_Pong:
		{
			return true;
		}
	}
	
	// This is an unknown OPCODE?! OMG
	LogError("Received invalid opcode = %d", _:vFrame[OPCODE]);
//	CloseConnection(s, 1002, "Invalid opcode");
	return true;
}

/**************************************
 * 연결 종료
 **************************************/

// Close the connection by initiating the connection close handshake with the CLOSE opcode
stock void CloseConnection(Handle s, int iCloseReason, char[] sPayLoad)
{
	int vFrame[WebsocketFrame];
	vFrame[OPCODE] = FrameType_Close;
	vFrame[CLOSE_REASON] = iCloseReason;
	vFrame[PAYLOAD_LEN] = strlen(sPayLoad);
	SendWebsocketFrame(s, sPayLoad, vFrame);
	
	g_bIsConnected = false;
	
	if(s != null) {
		SocketDisconnect(s);
		CloseHandle(s);
	}
}

/**************************************
 * 기타 스톡 함수들
 **************************************/

stock bindec(const char[] sBinary)
{
	int ret, len = strlen(sBinary);
	for(new i=0;i<len;i++)
	{
		ret = ret<<1;
		if(sBinary[i] == '1')
			ret |= 1;
	}
	return ret;
}

stock void Debug(iDebugLevel, char[] fmt, any:...)
{
#if DEBUG > 0

	if(iDebugLevel > DEBUG)
		return;
	char sBuffer[512];
	VFormat(sBuffer, sizeof(sBuffer), fmt, 3);
//	LogToFile(g_sLog, sBuffer);
	PrintToServer(sBuffer);
#endif
}