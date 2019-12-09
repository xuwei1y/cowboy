%% Copyright (c) 2017, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(http2_SUITE).
-compile(export_all).
-compile(nowarn_export_all).

-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).
-import(ct_helper, [get_remote_pid_tcp/1]).
-import(ct_helper, [name/0]).
-import(cowboy_test, [gun_open/1]).

all() -> [{group, clear}].

groups() -> [{clear, [parallel], ct_helper:all(?MODULE)}].

init_routes(_) -> [
	{"localhost", [
		{"/", hello_h, []},
		{"/echo/:key", echo_h, []},
		{"/resp_iolist_body", resp_iolist_body_h, []}
	]}
].

%% Do a prior knowledge handshake (function originally copied from rfc7540_SUITE).
do_handshake(Config) ->
	do_handshake(#{}, Config).

do_handshake(Settings, Config) ->
	{ok, Socket} = gen_tcp:connect("localhost", config(port, Config), [binary, {active, false}]),
	%% Send a valid preface.
	ok = gen_tcp:send(Socket, ["PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", cow_http2:settings(Settings)]),
	%% Receive the server preface.
	{ok, << Len:24 >>} = gen_tcp:recv(Socket, 3, 1000),
	{ok, << 4:8, 0:40, _:Len/binary >>} = gen_tcp:recv(Socket, 6 + Len, 1000),
	%% Send the SETTINGS ack.
	ok = gen_tcp:send(Socket, cow_http2:settings_ack()),
	%% Receive the SETTINGS ack.
	{ok, << 0:24, 4:8, 1:8, 0:32 >>} = gen_tcp:recv(Socket, 9, 1000),
	{ok, Socket}.

inactivity_timeout(Config) ->
	doc("Terminate when the inactivity timeout is reached."),
	ProtoOpts = #{
		env => #{dispatch => cowboy_router:compile(init_routes(Config))},
		inactivity_timeout => 1000
	},
	{ok, _} = cowboy:start_clear(name(), [{port, 0}], ProtoOpts),
	Port = ranch:get_port(name()),
	{ok, Socket} = do_handshake([{port, Port}|Config]),
	receive after 1000 -> ok end,
	%% Receive a GOAWAY frame back with an INTERNAL_ERROR.
	{ok, << _:24, 7:8, _:72, 2:32 >>} = gen_tcp:recv(Socket, 17, 1000),
	ok.

initial_connection_window_size(Config) ->
	doc("Confirm a WINDOW_UPDATE frame is sent when the configured "
		"connection window is larger than the default."),
	ConfiguredSize = 100000,
	ProtoOpts = #{
		env => #{dispatch => cowboy_router:compile(init_routes(Config))},
		initial_connection_window_size => ConfiguredSize
	},
	{ok, _} = cowboy:start_clear(name(), [{port, 0}], ProtoOpts),
	Port = ranch:get_port(name()),
	{ok, Socket} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
	%% Send a valid preface.
	ok = gen_tcp:send(Socket, ["PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", cow_http2:settings(#{})]),
	%% Receive the server preface.
	{ok, << Len:24 >>} = gen_tcp:recv(Socket, 3, 1000),
	{ok, << 4:8, 0:40, _:Len/binary >>} = gen_tcp:recv(Socket, 6 + Len, 1000),
	%% Receive a WINDOW_UPDATE frame incrementing the connection window to 100000.
	{ok, <<4:24, 8:8, 0:41, Size:31>>} = gen_tcp:recv(Socket, 13, 1000),
	ConfiguredSize = Size + 65535,
	ok.

max_frame_size_sent(Config) ->
	doc("Confirm that frames sent by Cowboy are limited in size "
		"by the max_frame_size_sent configuration value."),
	MaxFrameSize = 20000,
	ProtoOpts = #{
		env => #{dispatch => cowboy_router:compile(init_routes(Config))},
		max_frame_size_sent => MaxFrameSize
	},
	{ok, _} = cowboy:start_clear(name(), [{port, 0}], ProtoOpts),
	Port = ranch:get_port(name()),
	{ok, Socket} = do_handshake(#{max_frame_size => MaxFrameSize + 10000}, [{port, Port}|Config]),
	%% Send a request with a 30000 bytes body.
	{HeadersBlock, _} = cow_hpack:encode([
		{<<":method">>, <<"POST">>},
		{<<":scheme">>, <<"http">>},
		{<<":authority">>, <<"localhost">>}, %% @todo Correct port number.
		{<<":path">>, <<"/echo/read_body">>}
	]),
	ok = gen_tcp:send(Socket, [
		cow_http2:headers(1, nofin, HeadersBlock),
		cow_http2:data(1, nofin, <<0:16384/unit:8>>),
		cow_http2:data(1, fin, <<0:13616/unit:8>>)
	]),
	%% Receive a HEADERS frame as a response.
	{ok, << SkipLen:24, 1:8, _:8, 1:32 >>} = case gen_tcp:recv(Socket, 9, 1000) of
		%% We received a WINDOW_UPDATE first. Skip it and the next.
		{ok, <<4:24, 8:8, 0:40>>} ->
			{ok, _} = gen_tcp:recv(Socket, 4 + 13, 1000),
			gen_tcp:recv(Socket, 9, 1000);
		Res ->
			Res
	end,
	{ok, _} = gen_tcp:recv(Socket, SkipLen, 6000),
	%% The DATA frames following must have lengths of 20000
	%% and then 10000 due to the limit.
	{ok, <<20000:24, 0:8, _:40, _:20000/unit:8>>} = gen_tcp:recv(Socket, 20009, 6000),
	{ok, <<10000:24, 0:8, _:40, _:10000/unit:8>>} = gen_tcp:recv(Socket, 10009, 6000),
	%% Stop the listener.
	cowboy:stop_listener(name()).

preface_timeout_infinity(Config) ->
	doc("Ensure infinity for preface_timeout is accepted."),
	ProtoOpts = #{
		env => #{dispatch => cowboy_router:compile(init_routes(Config))},
		preface_timeout => infinity
	},
	{ok, _} = cowboy:start_clear(name(), [{port, 0}], ProtoOpts),
	Port = ranch:get_port(name()),
	{ok, Socket} = do_handshake([{port, Port}|Config]),
	Pid = get_remote_pid_tcp(Socket),
	Ref = erlang:monitor(process, Pid),
	receive
		{'DOWN', Ref, process, Pid, Reason} ->
			error(Reason)
	after 1000 ->
		cowboy:stop_listener(name())
	end.

resp_iolist_body(Config) ->
	doc("Regression test when response bodies are iolists that "
		"include improper lists, empty lists and empty binaries. "
		"The original issue failed to split the body into frames properly."),
	ProtoOpts = #{
		env => #{dispatch => cowboy_router:compile(init_routes(Config))}
	},
	{ok, _} = cowboy:start_clear(name(), [{port, 0}], ProtoOpts),
	Port = ranch:get_port(name()),
	ConnPid = gun_open([{type, tcp}, {protocol, http2}, {port, Port}|Config]),
	Ref = gun:get(ConnPid, "/resp_iolist_body"),
	{response, nofin, 200, RespHeaders} = gun:await(ConnPid, Ref),
	{_, BinLen} = lists:keyfind(<<"content-length">>, 1, RespHeaders),
	Len = binary_to_integer(BinLen),
	{ok, RespBody} = gun:await_body(ConnPid, Ref),
	Len = iolist_size(RespBody),
	gun:close(ConnPid).

settings_timeout_infinity(Config) ->
	doc("Ensure infinity for settings_timeout is accepted."),
	ProtoOpts = #{
		env => #{dispatch => cowboy_router:compile(init_routes(Config))},
		settings_timeout => infinity
	},
	{ok, _} = cowboy:start_clear(name(), [{port, 0}], ProtoOpts),
	Port = ranch:get_port(name()),
	{ok, Socket} = do_handshake([{port, Port}|Config]),
	Pid = get_remote_pid_tcp(Socket),
	Ref = erlang:monitor(process, Pid),
	receive
		{'DOWN', Ref, process, Pid, Reason} ->
			error(Reason)
	after 1000 ->
		cowboy:stop_listener(name())
	end.
