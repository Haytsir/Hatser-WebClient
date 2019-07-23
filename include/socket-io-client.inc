#if defined _socket_io_client_included
 #endinput
#endif
#define _socket_io_client_included

public SharedPlugin __pl_SOCKETIOCLIENT =
{
	name = "socket-io-client",
	file = "socket-io-client.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

enum EngineIOPacketType
{
	EngineIO_Open = 0,
	EngineIO_Close = 1,
	EngineIO_Ping = 2,
	EngineIO_Pong = 3,
	EngineIO_Message = 4,
	EngineIO_Upgrade = 5,
	EngineIO_Noop = 6	
}

enum SocketIOPacketType
{
	SocketIO_Connect = 0,
	SocketIO_Disconnect = 1,
	SocketIO_Event = 2,
	SocketIO_Ack = 3,
	SocketIO_Error = 4,
	SocketIO_Binary_Event = 5,
	SocketIO_Binary_Ack = 6,
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
forward void SocketIOClient_OnReceiveData (Handle socket, EngineIOPacketType iEIOPType, SocketIOPacketType iSIOPType, const char[] sEventName, ArrayList hDataArray);