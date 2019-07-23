#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#undef REQUIRE_PLUGIN
#include "include/socket-io-client.inc"
#include "include/BST-WebClient-Main.inc"
#define REQUIRE_PLUGIN
#include "include/EasyJSON.inc"

#pragma newdecls required

/*
	서버측에서 확인하는 순서..
	1. 서버 캐시에 데이터가 있는가? 있다면 그 정보를 보냄
	2. 서버가 소켓과 연결되어 있는가? 있다면 찾아서 캐시에 저장하고 그 정보를 보냄
	3. 서버 쿼리를 사용하여 데이터를 보냄
*/

char sHostname[128];
char sModName[64];
char sDescription[64];
char sMap[64];

char sTeamNames[2][32];

public Plugin myinfo = 
{
	name = "Web Client - Server Info",
	author = "Trostal",
	description = "Serve server and players' info to web server",
	version = SOURCEMOD_VERSION,
	url = ""
};

public void OnPluginStart()
{
	GetGameFolderName(sModName, sizeof(sModName));
	GetGameDescription(sDescription, sizeof(sDescription));
	GetCurrentMap(sMap, sizeof(sMap));
}

public void OnMapStart()
{
	GetCurrentMap(sMap, sizeof(sMap));
}

public void SocketIOClient_OnReceiveData(Handle socket, EngineIOPacketType iEIOPType, SocketIOPacketType iSIOPType, const char[] sEventName, ArrayList hDataArray)
{
	if(StrEqual(sEventName, "RequestServerInfo", false)) {
		SendServerInfo(socket);
	}
}

void SendServerInfo(Handle& socket) {
	// 전처리 단계
	Handle tmp = FindConVar("hostname");
	GetConVarString(tmp, sHostname, sizeof(sHostname)); 
	
	tmp = FindConVar("mp_teamname_1");
	GetConVarString(tmp, sTeamNames[0], sizeof(sTeamNames[])); 
	
	tmp = FindConVar("mp_teamname_2");
	GetConVarString(tmp, sTeamNames[1], sizeof(sTeamNames[])); 
	delete tmp;
	
	char sIP[20];
	int  iPort;
	
	WebClient_GetServerIP(sIP, sizeof(sIP));
	
	iPort = WebClient_GetServerPort();
	
	Handle hJSONMain = CreateJSON();
	
	// 서버 정보
	Handle hJSONServerInfo = CreateJSON();
	JSONSetString(hJSONServerInfo, "hostname", sHostname);
	JSONSetString(hJSONServerInfo, "game", sModName);
	JSONSetString(hJSONServerInfo, "ip", sIP);
	JSONSetInteger(hJSONServerInfo, "port", iPort);
	JSONSetString(hJSONServerInfo, "description", sDescription);
	JSONSetString(hJSONServerInfo, "map", sMap);
	JSONSetInteger(hJSONServerInfo, "players", GetClientCount(false));
	JSONSetInteger(hJSONServerInfo, "maxplayers", GetMaxHumanPlayers());
	
	JSONSetObject(hJSONMain, "server", hJSONServerInfo);
	
	// 팀 정보
	Handle hJSONTeamInfo = CreateJSON();
	JSONSetString(hJSONTeamInfo, "teamname1", sTeamNames[0]);
	JSONSetString(hJSONTeamInfo, "teamname2", sTeamNames[1]);
	JSONSetInteger(hJSONTeamInfo, "teamscore1", CS_GetTeamScore(3));
	JSONSetInteger(hJSONTeamInfo, "teamscore2", CS_GetTeamScore(2));
	JSONSetInteger(hJSONTeamInfo, "teamplayers1", GetTeamClientCount(3));
	JSONSetInteger(hJSONTeamInfo, "teamplayers2", GetTeamClientCount(2));
	
	JSONSetObject(hJSONMain, "team", hJSONTeamInfo);
	
	// 플레이어 정보
	Handle hJSONPlayerInfo = CreateJSON();
	
	Handle hJSONTeamInfos[4];
	hJSONTeamInfos[0] = CreateJSON();
	hJSONTeamInfos[1] = CreateJSON();
	hJSONTeamInfos[2] = CreateJSON();
	hJSONTeamInfos[3] = CreateJSON();
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsClientConnected(i) && !IsClientSourceTV(i))
		{
			char sAuthId[32];
			char sName[MAX_NAME_LENGTH];
			int iTeam = GetClientTeam(i);
			GetClientName(i, sName, sizeof(sName));
			
			Handle hJSONClientInfo = CreateJSON();
			
			if(!IsFakeClient(i)) {
				GetClientAuthId(i, AuthId_SteamID64, sAuthId, sizeof(sAuthId));
				JSONSetBoolean(hJSONClientInfo, "admin", GetUserAdmin(i) != INVALID_ADMIN_ID ? true : false);
			} else {
				Format(sAuthId, sizeof(sAuthId), "BOT#%i", GetClientSerial(i));
				JSONSetBoolean(hJSONClientInfo, "bot", true);
			}
			JSONSetString(hJSONClientInfo, "authid", sAuthId);
			JSONSetString(hJSONClientInfo, "name", sName);
			JSONSetInteger(hJSONClientInfo, "kills", GetClientFrags(i));
			JSONSetInteger(hJSONClientInfo, "deaths", GetClientDeaths(i));
			JSONSetInteger(hJSONClientInfo, "assists", CS_GetClientAssists(i));
			JSONSetInteger(hJSONClientInfo, "mvpcount", CS_GetMVPCount(i));
			JSONSetInteger(hJSONClientInfo, "score", CS_GetClientContributionScore(i));
		
		//  Heap에 공간적 여유가 없어서 어레이로 만들어서 보내는데 제한이 생긴다.
		//  먼저 오브젝트로 보내놓고 웹서버에서 처리하자.
		//	PushArrayCell(hJSONTeamInfos[iTeam], hJSONClientInfo);
			JSONSetObject(hJSONTeamInfos[iTeam], sAuthId, hJSONClientInfo);
		}
	}
	
	
	JSONSetObject(hJSONPlayerInfo, "team1", hJSONTeamInfos[3]);
	JSONSetObject(hJSONPlayerInfo, "team2", hJSONTeamInfos[2]);
	JSONSetObject(hJSONPlayerInfo, "spectators", hJSONTeamInfos[1]);
	JSONSetObject(hJSONPlayerInfo, "unassigned", hJSONTeamInfos[0]);
	
	JSONSetObject(hJSONMain, "players", hJSONPlayerInfo);
	
	
	char result[4098];
	EncodeJSON(hJSONMain, result, sizeof(result), false);
	char payload[5120];
	Format(payload, sizeof(payload), "%i%i[\"ServerInfo\", %s]", EngineIO_Message, SocketIO_Event, result);
	WebClient_Send(socket, view_as<WebsocketSendType>(SendType_Text), payload, strlen(payload));
	DestroyJSON(hJSONMain);
}