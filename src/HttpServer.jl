# HttpServer module
#
# Serve HTTP requests in Julia.
#
__precompile__()
module HttpServer

using Compat; import Compat.String
using HttpCommon
using MbedTLS
using HTTP2.Session

include("RequestParser.jl")

export HttpHandler,
       Server,
       run,
       write,
       # from HttpCommon
       Request,
       Response,
       escapeHTML,
       parsequerystring,
       setcookie!

import Base: run, listen, close

defaultevents = Dict{String, Function}()
defaultevents["error"]  = ( client, err )->println( err )
defaultevents["listen"] = ( saddr )      ->println("Listening on $saddr...")

"""
`HttpHandler` types are used to instantiate a `Server`.

An `HttpHandler` is responsible for the entirety of the request / response
cycle. Instantiate an `HttpHandler` with a single `Function` argument, which
becomes `HttpHandler.handle`. This handler is called on every incoming
request and passed `req::Request, res::Response`. The return value of
`HttpHandler.handle` is the response sent to the client for the given `req`.

`HttpHandler.handle` can return a `AbstractString`:

```
handler = HttpHandler() do req, res
  "Hello world!"
end
```

an HTTP status code as `Int`:

```
handler = HttpHandler() do req, res
  404
end
```

or a full `Response` instance:

```
handler = HttpHandler() do req, res
  Response(200, "Success", "Hello World!"
end
```


`HttpHandler.sock` is used internally to store the `TcpSocket` for incoming
connections.

`HttpHandler.events` is a dictionary of functions to call when certain
server events occur.
Set these functions by direct assignment:

```
handler.events["listen"] = (port) "Listening on \$port..."
```

All default events and their arguments:

* `"listen"  => (port::Int)`
* `"connect" => (client::Client)`
* `"write"   => (client::Client, res::Response)`
* `"close"   => (client::Client)`

If you want to trigger custom events on your server, use the `event`
function:

```
# listen for "foo"
handler.events["foo"] = (bar) "Hello \$bar"
# trigger "foo"
HttpServer.event(server, "foo", "Julia")
```
"""
immutable HttpHandler
    handle::Function
    sock::Base.TCPServer
    events::Dict

    HttpHandler(handle::Function, sock::Base.TCPServer) = new(handle, sock, defaultevents)
    HttpHandler(handle::Function) = new(handle, Base.TCPServer(), defaultevents)
end
handle(handler::HttpHandler, req::Request, res::Response) = handler.handle(req, res)

""" Client encapsulates a single connection

 When new connections are initialized a `Client` is created with a new id and
 the connection socket. `Client.parser` will store a `ClientParser` to handle
 all HTTP parsing for the connection lifecycle.
"""
type Client{T<:IO}
    id::Int
    sock::T
    parser::ClientParser

    Client(id::Int,sock::T) = new(id,sock)
end
Client{T<:IO}(id::Int,sock::T) = Client{T}(id,sock)

""" `WebSocketInterface` defines the abstract protocol for a WebSocketHandler.

The methods `is_websocket_handshake` and `handle` will be called if `Server.
sockets` is populated. Concrete types of `WebSocketInterface` are required
to define these methods.
"""
abstract WebSocketInterface

""" `is_websocket_handshake` should determine if `req` is a valid websocket
upgrade request.
"""
function is_websocket_handshake(handler::WebSocketInterface, req::Request)
    throw("`$(typeof(handler))` does not implement `is_websocket_handshake`.")
end

""" `handle` is called when `is_websocket_handshake` returns true, and takes
full control of the connection.
"""
function handle(handler::WebSocketInterface, req::Request, client::Client)
    throw("`$(typeof(handler))` does not implement `handle`.")
end

""" `Server` types encapsulate an `HttpHandler` and optional
`WebSocketInterface` to serve requests.

* Instantiate with both an `HttpHandler` and `WebSocketInterface` to serve
  both protocols.
* Instantiate with just an `HttpHandler` to serve only standard `Http`
* Instantiate with a `HttpHandler` and `true` to serve with HTTP/2.
* Instantiate with just a `Function` to create an `HttpHandler` automatically
* Instantiate with just a `WebSocketInterface` to only serve websockets
  requests and `404` all others.
"""
immutable Server
    http::HttpHandler
    websock::Union{Void, WebSocketInterface}
    is_http2::Bool
end
Server(http::HttpHandler)           = Server(http, nothing, false)
Server(http::HttpHandler, is_http2::Bool) = Server(http, nothing, is_http2)
Server(handler::Function)           = Server(HttpHandler(handler))
Server(websock::WebSocketInterface) = Server(HttpHandler((req, res)->Response(404)), websock, false)

"""Triggers `event` on `server`.

If there is a function bound to `event` in `server.events` it will be called
with `args...`
"""
function event(event::AbstractString, server::Server, args...)
    haskey(server.http.events, event) && server.http.events[event](args...)
end

"""
Sets a cookie with the given name, value, and attributes on the given response object.
"""
setcookie!(r::Response, name, value=utf8(""), attrs=Dict{String, String}()) =
  setcookie!(r, Cookie(name, value, attrs))

setcookie!(r::Response, cookie::Cookie) = (r.cookies[cookie.name] = cookie; r)

import Base.write
"Converts a `Response` to an HTTP response string"
function write(io::IO, response::Response)
    write(io, join(["HTTP/1.1", response.status, HttpCommon.STATUS_CODES[response.status], "\r\n"], " "))

    response.headers["Content-Length"] = string(sizeof(response.data))
    for (header,value) in response.headers
        write(io, string(join([ header, ": ", value ]), "\r\n"))
    end
    for (cookie_name, cookie) in response.cookies
        write(io, "Set-Cookie: ", cookie_name, "=", cookie.value)
        for (attr_name, attr_val) in cookie.attrs
            write(io, "; ", attr_name)
            if !isempty(attr_val)
                write(io, "=", attr_val)
            end
        end
        write(io, "\r\n")
    end

    write(io, "\r\n")
    write(io, response.data)
end

""" Start `server` to listen on specified socket address.

    listen(server::Server, host::Base.IPAddr, port::Integer) Server

    Setup "server" so it listens on "port" on the address specified by "host".
    To listen on all interfaces pass, "IPv4(0)" or "IPv6(0)" as appropriate.
"""
function listen(server::Server, host::Base.IPAddr, port::Integer)
    Base.uv_error("listen", !bind(server.http.sock, host, UInt16(port)))
    listen(server.http.sock)
    inet = "$host:$port"
    event("listen", server, inet)
    return server
end
listen(server::Server, port::Integer) = listen(server, IPv4(0), port)

if is_unix()
    @doc """
Start `server` to listen on named pipe/domain socket.

    listen(server::Server, path::AbstractString) Server

Setup "server" to listen on named pipe/domain socket specified by "path".
    """ ->
    function listen(server::Server, path::AbstractString)
        bind(server.http.sock, path) || throw(ArgumentError("could not listen on path $path"))
        Base.uv_error("listen", Base._listen(server.http.sock))
        event("listen", server, path)
        return server
    end
end

""" Handle HTTP request from client """
function handle_http_request(server::Server)
    id_pool = 0 # Increments for each connection
    websockets_enabled = server.websock != nothing
    while true # handle requests, Base.wait_accept blocks until a connection is made
        sock = TCPSocket()
        try
            sock = accept(server.http.sock)
        catch e
            if !isopen(server.http.sock)
                # Server was closed while waiting to accept client. Exit gracefully.
                break
            end
            throw(e)
        end

        client = Client(id_pool += 1, sock)
        if server.is_http2
            @async process_client2(server, client)
        else
            client.parser = ClientParser(message_handler(server, client, websockets_enabled))
            @async process_client(server, client, websockets_enabled)
        end
    end
end

""" Handle HTTPS request from client """
function handle_https_request(server::Server, ssl_config::MbedTLS.SSLConfig)
    id_pool = 0 # Increments for each connection
    websockets_enabled = server.websock != nothing
    while true
        sess = MbedTLS.SSLContext()
        MbedTLS.setup!(sess, ssl_config)
        sock = TCPSocket()
        # set_priority_string!(sess)
        # set_credentials!(sess, cert_store)
        try
            sock = accept(server.http.sock)
        catch e
            if !isopen(server.http.sock)
                # Server was closed while waiting to accept client. Exit gracefully.
                break
            end
            throw(e)
        end
        try
            MbedTLS.set_bio!(sess, sock)
            MbedTLS.handshake(sess)
            # associate_stream(sess, client)
            # handshake!(sess)
        catch e
            println("Error establishing SSL connection: ", e)
            close(sock)
            continue
        end

        client = Client(id_pool += 1, sess)
        if server.is_http2
            @async process_client2(server, client)
        else
            client.parser = ClientParser(message_handler(server, client, websockets_enabled))
            @async process_client(server, client, websockets_enabled)
        end
    end
end

function default_ssl_config(ssl_cert, key; http2=false)
    conf = MbedTLS.SSLConfig()
    entropy = MbedTLS.Entropy()
    rng = MbedTLS.CtrDrbg()
    MbedTLS.config_defaults!(conf, endpoint=MbedTLS.MBEDTLS_SSL_IS_SERVER)
    MbedTLS.seed!(rng, entropy)
    MbedTLS.rng!(conf, rng)
    MbedTLS.own_cert!(conf, ssl_cert, key)

    if http2
        MbedTLS.set_alpn!(conf, ["h2"])
    end

    MbedTLS.dbg!(conf, (level, filename, number, msg)->begin
        warn("MbedTLS emitted debug info: $msg in $filename:$number")
    end)
    conf
end

function handle_https_request(server::Server, ssl_cert::Tuple{MbedTLS.CRT, MbedTLS.PKContext})
    handle_https_request(server, default_ssl_config(ssl_cert...; http2=server.is_http2))
end

""" `run` starts `server`

Functionality:

* Accepts incoming connections and instantiates each `Client`.
* Manages the `client.id` pool.
* Spawns a new `Task` for each connection.
* Blocks forever.

Method accepts following keyword arguments:

* host - binding address
* port - binding port
* ssl  - SSL configuration. Use this argument to enable HTTPS support.
Can be either an MbedTLS.SSLConfig object that already
has associated certificates, or a tuple of an MbedTLS.CRT (certificate) and
MbedTLS.PKContext (private key)). In the latter case, a configuration with reasonable
defaults will be used.

* socket - named pipe/domain socket path. Use this argument to enable Unix socket support.
It's available only on Unix. Network options are ignored.

Compatibility:

* for backward compatibility use `run(server::Server, port::Integer)`

Example:
```
server = Server() do req, res
  "Hello world"
end

# start server on localhost
run(server, host=IPv4(127,0,0,1), port=8000)
# or
run(server, 8000)
```
"""
function run(server::Server; args...)
    params = Dict(args)

    # parse parameters
    port = get(params, :port, 0)
    host = get(params, :host, IPv4(0))
    use_https = haskey(params, :ssl)
    use_sockets = is_unix() ? (haskey(params, :socket) && !haskey(params, :port)) : false

    server = if use_sockets
        listen(server, params[:socket])  # start server on Unix socket
    else
        host, port
        listen(server, host, port)       # start server on network socket
    end

    if use_https
        handle_https_request(server, params[:ssl])
    else
        handle_http_request(server)
    end
end
# backward compatibility method
run(server::Server, port::Integer) = run(server, port=port)

"""Handle HTTP/2 live connections.

This function initialize to process a HTTP/2 client. It tries to use HTTP/2
protocol upgrade first, and then call `process_client_callback2`.
"""
function process_client2(server::Server, client::Client; server_preface=false)
    CLIENT_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
    pre = readbytes(client.sock, length(CLIENT_PREFACE))

    if pre != CLIENT_PREFACE
        # This is an upgrade request
        client.parser = ClientParser(message_handler_upgrade2(server, client))
        add_data(client.parser, pre)
        @async process_client(server, client, false)
    else
        process_client_callback2(server, client; skip_preface=true)
    end
end

"""Handle HTTP/2 live connections callback.

This function processes after the initial HTTP/1.1 parser finished parsing
headers (for HTTP/2 protocol upgrade) or directly enters a HTTP/2 connection.
"""
function process_client_callback2(server::Server, client::Client; skip_preface=false)
    connection = Session.new_connection(client.sock; isclient=false, skip_preface=skip_preface)

    headers_evt = Session.take_evt!(connection)
    @assert isa(headers_evt, Session.EvtRecvHeaders)
    headers = headers_evt.headers
    main_stream_identifier = headers_evt.stream_identifier

    method = headers[":method"]
    resource = headers[":path"]

    if headers_evt.is_end_stream
        data = Array{UInt8, 1}()
    else
        data_evt = Session.take_evt!(connection)
        @assert isa(data_evt, Session.EvtRecvData)
        data = data_evt.data
    end

    request = Request(method, resource, headers, data)
    response = handle(server.http, request, Response())
    if !(isa(response, Response) || isa(response, Tuple{Response, Vector{Tuple{Request, Response}}}))
        response = Response(response)
    end

    if isa(response, Response)
        Session.put_act!(connection, Session.ActSendHeaders(main_stream_identifier, response.headers, false))
        Session.put_act!(connection, Session.ActSendData(main_stream_identifier, response.data, true))
    elseif isa(response, Tuple{Response, Vector{Tuple{Request, Response}}}) && length(response[2]) > 0
        Session.put_act!(connection, Session.ActSendHeaders(main_stream_identifier, response[1].headers, false))
        for i = 1:length(response[2])
            promised = response[2][i]
            promised_stream_identifier = Session.next_free_stream_identifier(connection)
            Session.put_act!(connection, Session.ActPromise(main_stream_identifier, promised_stream_identifier,
                                            promised[1].headers))
            Session.put_act!(connection, Session.ActSendHeaders(promised_stream_identifier, promised[2].headers, false))
            Session.put_act!(connection, Session.ActSendData(promised_stream_identifier, promised[2].data, true))
        end
        Session.put_act!(connection, Session.ActSendData(main_stream_identifier, response[1].data, true))
    else
        @assert false
    end

    event("close", server, client)
end

"""Handles live connections, runs inside a `Task`.

Blocks ( yields ) until a line can be read, then passes it into `client.
parser`.
"""
function process_client(server::Server, client::Client, websockets_enabled::Bool)
    event("connect", server, client)

    while !eof(client.sock)#isopen(client.sock)
        # try
            if !upgrade(client.parser.parser)
                # IMPORTANT NOTE: This is technically incorrect as there may be data
                # in the buffer that we have not yet read. The way to deal with this
                # is to manually adjust the position of the buffer, but for that to
                # happen, we need use the return value of http_parser_execute, which
                # we don't have, since we launch websocket handlers in the callback.
                # Anyway, since there always needs to be a handshake this is probably
                # fine for now.
                data = readavailable(client.sock)
                if length(data) > 0
                    add_data(client.parser, data)
                end
            else
                wait(client.sock.closenotify)
            end
        # catch e
        #     if isa(e,GnuTLS.GnuTLSException) && e.code == -110
        #         # Because Chrome is buggy on OS X, ignore E_PREMATURE_TERMINATION
        #     else
        #         rethrow()
        #     end
        # end
    end
    event("close", server, client)
end

""" Closes the Server `server` by closing the underlying TCPServer `sock` in the HttpHandler. """
close(server::Server) = close(server.http.sock)

"Callback factory for providing `on_message_complete` for `client.parser`"
function message_handler(server::Server, client::Client, websockets_enabled::Bool)

    # Called when the `ClientParser` has finished parsing a `Request`.
    #
    # If websockets are enabled and claim this request, defer to `server.
    # websock` and return. Otherwise, call `server.http.handle` to get a
    # `Response` for the `client`. Catches any errors with `server.http.
    # handle`, returns a `500` and writes a stacktrace to `stdout`.
    #
    function on_message_complete(req::Request)
        if websockets_enabled && is_websocket_handshake(server.websock, req)
            handle(server.websock, req, client)
            return true
        end

        local response

        try
            response = handle(server.http, req, Response()) # Run the server handler
            if !isa(response, Response)                     # Promote return to Response
                response = Response(response)
            end
        catch err
            response = Response(500)
            event("error", server, client, err)
            Base.display_error(err, catch_backtrace())      # Prints backtrace without throwing
        end

        # We have a Keep-Alive header set to 0 or 1 in RequestParser
        # to denote if the client wants keep-alive or not
        # We also have to check if the server wants to close the connection
        # If this is keep-alive, we need to add Connection header with keep-alive
        local keep_alive = get(req.headers, "Keep-Alive", nothing) == "1" &&
                           get(response.headers, "Connection", nothing) != "close"
        if keep_alive
            response.headers["Connection"] = "keep-alive"
        end

        write(client.sock, response)
        event("write", server, client, response)

        if !keep_alive
            close(client.sock)
        end
    end
end

function message_handler_upgrade2(server::Server, client::Client)

    # Called when the `ClientParser` has finished parsing a `Request`.
    #
    # If websockets are enabled and claim this request, defer to `server.
    # websock` and return. Otherwise, call `server.http.handle` to get a
    # `Response` for the `client`. Catches any errors with `server.http.
    # handle`, returns a `500` and writes a stacktrace to `stdout`.
    #
    function on_message_complete(req::Request)
        local response

        # @assert req.headers["Upgrade"] == "h2c"

        response = Response(101)
        response.headers["Connection"] = "Upgrade"
        response.headers["Upgrade"] = "h2c"

        write(client.sock, response)

        process_client_callback2(server, client; skip_preface=false)
    end
end


include("mimetypes.jl")

function FileResponse(filename)
    if isfile(filename)
        s = open(readbytes,filename)
        (_, ext) = splitext(filename)
        mime = length(ext)>1 && haskey(mimetypes,ext[2:end]) ? mimetypes[ext[2:end]] : "application/octet-stream"
        Response(200, Dict{AbstractString,AbstractString}([("Content-Type",mime)]), s)
    else
        Response(404, "Not Found - file $filename could not be found")
    end
end


function __init__()
    # Turn all the callbacks into C callable functions.
    global const on_message_begin_cb = cfunction(on_message_begin, HTTP_CB...)
    global const on_url_cb = cfunction(on_url, HTTP_DATA_CB...)
    global const on_status_complete_cb = cfunction(on_status_complete, HTTP_CB...)
    global const on_header_field_cb = cfunction(on_header_field, HTTP_DATA_CB...)
    global const on_header_value_cb = cfunction(on_header_value, HTTP_DATA_CB...)
    global const on_headers_complete_cb = cfunction(on_headers_complete, HTTP_CB...)
    global const on_body_cb = cfunction(on_body, HTTP_DATA_CB...)
    global const on_message_complete_cb = cfunction(on_message_complete, HTTP_CB...)
end

end # module HttpServer
