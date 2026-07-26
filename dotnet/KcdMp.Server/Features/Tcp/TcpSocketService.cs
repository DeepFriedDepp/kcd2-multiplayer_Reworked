using System.Net;
using System.Net.Sockets;
using KcdMp.Server.Features.ClientHandling;
using ILogger = Serilog.ILogger;

namespace KcdMp.Server.Features.Tcp;

/// <summary>
/// Background service that exposes a TCP socket and handles incoming traffic.
/// </summary>
public class TcpSocketService : BackgroundService
{
	private readonly ILogger _logger;
	private readonly int _port;
	private readonly ClientHandler _clientHandler;
	private readonly TcpBroadcastService _broadcastService;

	public TcpSocketService(ILogger logger, IConfiguration configuration,
		ClientHandler clientHandler, TcpBroadcastService broadcastService)
	{
		_logger = logger;

		var configSection = configuration.GetSection("Tcp");
		_port = int.Parse(configSection["Port"] ?? "7778");

		_clientHandler = clientHandler;
		_broadcastService = broadcastService;
	}

	/// <summary>
	/// The actual logic executed by the service on startup.
	///
	/// Handles the TCP socket.
	/// </summary>
	/// <param name="cancellationToken"></param>
	protected override async Task ExecuteAsync(CancellationToken cancellationToken)
	{
		var listener = new TcpListener(IPAddress.Any, _port);
		listener.Start();
		_logger.Information("Listening on port {Port}...", _port);
		_logger.Information("Waiting for clients to connect.");

		try
		{
			while (!cancellationToken.IsCancellationRequested)
			{
				var tcpListener = await listener.AcceptTcpClientAsync(cancellationToken);
				var client = new ClientSession(_logger, tcpListener, _broadcastService);

				_clientHandler.AddClient(client);

				// ClientHandler is thread-safe, so the disconnect bookkeeping needs no
				// lock and no async continuation of its own.
				_ = client.RunAsync().ContinueWith(_ =>
				{
					_clientHandler.RemoveClient(client);

					_logger.Information("[-] {ClientName} disconnected. Clients: {ClientHandlerClientCount}",
						client.Name ?? $"id={client.Id}", _clientHandler.ClientCount);
					if (client.IsReady)
						_broadcastService.BroadcastDisconnect(client);
				}, CancellationToken.None);
			}
		}
		catch (OperationCanceledException)
		{
			// Normal shutdown. TaskCanceledException derives from this, and
			// AcceptTcpClientAsync throws the base type on cancellation.
			_logger.Information("TCP Socket closed.");
		}
		finally
		{
			listener.Stop();
		}
	}
}
