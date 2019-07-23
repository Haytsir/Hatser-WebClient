# Hatser-WebClient
Sourcemod plugins those communicate with Hatser WebAPIServer, or any other Socket.io servers.

This plugin requires [Socket Extension](https://forums.alliedmods.net/showthread.php?t=67640),

this makes plain TCP sockets into corresponding websockets, then converts it once again into socket.io frames.

reference [here](https://forums.alliedmods.net/showthread.php?t=298782) to check out how does it handshakes with Websocket server.

Some codes of websocket client are taken from (peace-maker's sm-websocket)[https://github.com/peace-maker/sm-websocket] which simulate a websocket server.

I revert the processes to make it work as a websocket client.

check out [RFC 6455](https://tools.ietf.org/html/rfc6455) to see how websocket protocol works.

## 이미지
![](https://i.imgur.com/Dr5eWj8.gif)
