/* We like semicolons */
#pragma semicolon 1

#include <sourcemod>
#include <SteamWorks>
#include <BST-WebClient-Main>

#pragma newdecls required

int g_iServerId = -1;
Handle g_hForwardOnGetServerId = null;

Handle g_hCvar_DomainName =	INVALID_HANDLE;

public Plugin myinfo = 
{
	name = "Web Client (Core)",
	author = "Trostal",
	description = "The core plugin to interact with web server (Trostal)",
	version = SOURCEMOD_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_hCvar_DomainName = CreateConVar("bst_wc_domain_name", "", 	"현재 게임 서버가 사용하는 도메인 명, 공란으로 둘 시 IP로 검색합니다.");
	
	// forward void WebClient_OnGetServerID (int iServerId);
	g_hForwardOnGetServerId = CreateGlobalForward("WebClient_OnGetServerID", ET_Ignore, Param_Cell);	
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	// native void WebClient_GetServerIP(char[] buffer, int maxlen);
	CreateNative("WebClient_GetServerIP", Native_WebClient_GetServerIP);
	// native int WebClient_GetServerIP();
	CreateNative("WebClient_GetServerPort", Native_WebClient_GetServerPort);
	// native int WebClient_GetServerIP();
	CreateNative("WebClient_GetServerID", Native_WebClient_GetServerID);
	
	RegPluginLibrary("bst_webclient");
	return APLRes_Success;
}

public int Native_WebClient_GetServerIP(Handle plugin, int numParams)
{
	int ip[4];
	SteamWorks_GetPublicIP(ip);
	
	int len = GetNativeCell(2);
	char[] buffer = new char[len];
	
	Format(buffer, len, "%i.%i.%i.%i", ip[0], ip[1], ip[2], ip[3]);
	
	SetNativeString(1, buffer, len, false);
	
	return;
}

public int Native_WebClient_GetServerPort(Handle plugin, int numParams)
{	
	return Server_GetPort();
}

public int Native_WebClient_GetServerID(Handle plugin, int numParams)
{	
	return g_iServerId;
}

public int SteamWorks_SteamServersConnected()
{
	/* First try to get a database connection */
	char error[255];
	Database db;
	
	if (SQL_CheckConfig("web-client"))
	{
		db = SQL_Connect("web-client", true, error, sizeof(error));
	} else {
		db = SQL_Connect("default", true, error, sizeof(error));
	}
	
	if (db == null)
	{
		LogError("Could not connect to database \"default\": %s", error);
		return;
	} else {
		g_iServerId = GetServerId(db);
		Call_StartForward(g_hForwardOnGetServerId);
		Call_PushCell(g_iServerId);
		Call_Finish();
	}
	
	delete db;
}

int GetServerId(Database db)
{
	char query[255];
	DBResultSet rs;
	
	char sDomainName[254];
	GetConVarString(g_hCvar_DomainName, sDomainName, sizeof(sDomainName));
	
	int port = Server_GetPort();
	if(StrEqual(sDomainName, "")) {
		int ip[4];
		SteamWorks_GetPublicIP(ip);
		Format(sDomainName, sizeof(sDomainName), "%i.%i.%i.%i", ip[0], ip[1], ip[2], ip[3]);
	}
		
	Format(query, sizeof(query), "SELECT id FROM sm_servers WHERE address='%s' AND port='%i';", sDomainName, port);
	

	if ((rs = SQL_Query(db, query)) == null)
	{
		LogSQLError("GetServerId(1)", db, query);
		return -1;
	}
	
	// 서버가 등록되지 않았을 경우
	if (rs.RowCount <= 0)
	{
		PrintToServer("[BST WEB CLIENT] The server isn't allowed yet,");
		return -1;
	}
	
	int id = -1;
	if(rs.FetchRow())
	{
		id = rs.FetchInt(0);
	}
	
	return id;
}

stock void LogSQLError(const char[] functionName, Database db, const char[] query)
{
	char error[255];
	SQL_GetError(db, error, sizeof(error));
	LogError("%s query failed: %s", functionName, query);
	LogError("Query error: %s", error);
}

/*
 * Gets the server's public/external (default) or
 * private/local (usually server's behind a NAT) IP.
 * If your server is behind a NAT Router, you need the SteamTools
 * extension available at http://forums.alliedmods.net/showthread.php?t=129763
 * to get the public IP. <steamtools> has to be included BEFORE <smlib>.
 * If the server is not behind NAT, the public IP is the same as the private IP.
 * 
 * @param public		Set to true to retrieve the server's public/external IP, false otherwise.
 * @return				Long IP or 0 if the IP couldn't be retrieved.
 */
stock int Server_GetIP(bool public_=true)
{
	int ip = 0;

	static ConVar cvHostip = null;

	if (cvHostip == INVALID_HANDLE) {
		cvHostip = FindConVar("hostip");
		MarkNativeAsOptional("SteamWorks_GetPublicIP");
	}

	if (cvHostip != INVALID_HANDLE) {
		ip = cvHostip.IntValue;
	}

	if (ip != 0 && IsIPLocal(ip) == public_) {
		ip = 0;
	}

#if defined _SteamWorks_Included
	if (ip == 0) {
		if (CanTestFeatures() && GetFeatureStatus(FeatureType_Native, "SteamWorks_GetPublicIP") == FeatureStatus_Available) {
			int octets[4];
			SteamWorks_GetPublicIP(octets);

			ip =
				octets[0] << 24	|
				octets[1] << 16	|
				octets[2] << 8	|
				octets[3];

			if (IsIPLocal(ip) == public_) {
				ip = 0;
			}
		}
	}
#endif

	return ip;
}

/*
 * Gets the server's public/external (default) or
 * private/local (usually server's behind a NAT) as IP String in dotted format.
 * If your server is behind a NAT Router, you need the SteamTools
 * extension available at http://forums.alliedmods.net/showthread.php?t=129763
 * to get the public IP. <steamtools> has to be included BEFORE <smlib>.
 * If the public IP couldn't be found, an empty String is returned.
 * If the server is not behind NAT, the public IP is the same as the private IP.
 * 
 * @param buffer		String buffer (size=16)
 * @param size			String buffer size.
 * @param public		Set to true to retrieve the server's public/external IP, false otherwise.
 * @return				True on success, false otherwise.
 */
stock bool Server_GetIPString(char[] buffer, int size, bool public_=true)
{
	int ip;
	
	if ((ip = Server_GetIP(public_)) == 0) {
		buffer[0] = '\0';
		return false;
	}

	LongToIP(ip, buffer, size);

	return true;
}

/*
 * Gets the server's local port.
 *
 * @noparam
 * @return			The server's port, 0 if there is no port.
 */
stock int Server_GetPort()
{
	static ConVar cvHostport = null;
	
	if (cvHostport == null) {
		cvHostport = FindConVar("hostport");
	}

	if (cvHostport == null) {
		return 0;
	}

	int port = cvHostport.IntValue;

	return port;
}

/*
 * Gets the server's hostname
 *
 * @param hostname		String buffer
 * @param size			String buffer size
 * @return				True on success, false otherwise.
 */
stock bool Server_GetHostName(char[] buffer, int size)
{	
	static ConVar cvHostname = INVALID_HANDLE;
	
	if (cvHostname == null) {
		cvHostname = FindConVar("hostname");
	}

	if (cvHostname == null) {
		buffer[0] = '\0';
		return false;
	}

	cvHostname.GetString(buffer, size);

	return true;
}

/*
 * Converts a long IP to a dotted format String.
 * 
 * @param ip			IP Long
 * @param buffer		String Buffer (size = 16)
 * @param size			String Buffer size
 * @noreturn
 */
stock void LongToIP(int ip, char[] buffer, int size)
{
	Format(
		buffer, size,
		"%d.%d.%d.%d",
			(ip >> 24)	& 0xFF,
			(ip >> 16)	& 0xFF,
			(ip >> 8 )	& 0xFF,
			ip        	& 0xFF
		);
}

/*
 * Converts a dotted format String IP to a long.
 * 
 * @param ip			IP String
 * @return				Long IP
 */
stock int IPToLong(const char[] ip)
{
	char pieces[4][4];

	if (ExplodeString(ip, ".", pieces, sizeof(pieces), sizeof(pieces[])) != 4) {
		return 0;
	}

	return (
		StringToInt(pieces[0]) << 24	|
		StringToInt(pieces[1]) << 16	|
		StringToInt(pieces[2]) << 8		|
		StringToInt(pieces[3])
	);
}

static int localIPRanges[] = 
{
	10	<< 24,				// 10.
	127	<< 24 | 1		,	// 127.0.0.1
	127	<< 24 | 16	<< 16,	// 127.16.
	192	<< 24 | 168	<< 16,	// 192.168.
};

/*
 * Checks whether an IP is a private/internal IP
 * 
 * @param ip			IP Long
 * @return				True if the IP is local, false otherwise.
 */
stock bool IsIPLocal(int ip)
{
	int range, bits, move;
	bool matches;

	for (int i=0; i < sizeof(localIPRanges); i++) {

		range = localIPRanges[i];
		matches = true;

		for (int j=0; j < 4; j++) {
			move = j * 8;
			bits = (range >> move) & 0xFF;

			if (bits && bits != ((ip >> move) & 0xFF)) {
				matches = false;
			}
		}

		if (matches) {
			return true;
		}
	}

	return false;
}