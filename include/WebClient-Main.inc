#if defined _bst_webclient_included
 #endinput
#endif
#define _bst_webclient_included

public SharedPlugin __pl_BSTWEBCLIENT =
{
	name = "webclient",
	file = "WebClient-Main.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
	public __pl_WEBCLIENT_SetNTVOptional() {
		MarkNativeAsOptional("WebClient_UseWebsocketInterface");
		MarkNativeAsOptional("WebClient_Send");
		MarkNativeAsOptional("WebClient_UnuseWebsocketInterface");
	}
#endif
};

enum WebsocketReadyState {
	State_Connecting = 0,
	State_Open,
	State_Closing,
	State_Closed // Kinda unused
}

enum WebsocketHandle {
	INVALID_WEBSOCKET_HANDLE = 0
}

enum WebsocketSendType {
	SendType_Text = 0,
	SendType_Binary
}

/**
 * triggered if a websocket receives data
 *
 * @note This is binary safe if you always use dataSize for operations on receiveData[]
 * @note packets may be split up into multiple chunks -> multiple calls to the receive callback
 * @note if not set otherwise by SocketSetOption(..., ConcatenateCallbacks, ...) receiveData will
 *       never be longer than 4096 characters including \0 terminator
 *
 * @param Handle	websocket		The socket handle pointing to the calling socket
 * @param String	receiveData	The data which arrived, 0-terminated at receiveData[dataSize]
 * @param cell_t	dataSize	The length of the arrived data excluding the 0-termination
 * @noreturn
 */
typedef WebClientReceiveCB = function void (Handle socket, WebsocketSendType iType, const char[] sPayload, const int dataSize);

typedef WebClientReceivePlainCB = function Action (Handle socket, const char[] receiveData, const int dataSize, any arg);

/**
 * Creates a websocket server which listens on the supplied ip:port combination.
 *
 * @param sIP    	The IP to bind to.
 * @param iPort    		The port to listen on
 * @param connCB    		The incoming child connection callback
 * @param disconnCB    		The error callback
 * @return        		A WebsocketHandle or INVALID_WEBSOCKET_HANDLE on error.
 */
native bool WebClient_UseWebsocketInterface(Handle socket, WebsocketClientReceivePlainCB recvpCB, WebsocketClientReceiveCB recvCB);
native bool WebClient_UnuseWebsocketInterface(Handle socket);

/**
 * Sends text or binary data through the websocket
 *
 * @param socket    The child websocket to send to
 * @param type    			The datatype SendType_Text or SendType_Binary
 * @param sPayLoad 			The data to send
 * @param dataSize			If set, it's used as maxlength. Useful for binary data where \0 might be used before the end of the data.
 * @return        			True if child socket was hooked, false otherwise
 */
native bool WebClient_Send(Handle socket, WebsocketSendType type = SendType_Text, char[] sPayLoad, const int dataSize = -1);

native void WebClient_GetServerIP(char[] buffer, int maxlen);
native int WebClient_GetServerPort();
native int WebClient_GetServerID();
	
forward void WebClient_OnGetServerID (int iServerId);