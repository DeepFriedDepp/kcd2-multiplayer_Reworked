using System.Net;
using KcdMp.MasterServer.Features.Registry;

namespace KcdMp.MasterServer.Features.Announce;

/// <summary>Outcome of checking one announce. Exactly one of the first two is set.</summary>
/// <param name="Server">The listing to publish.</param>
/// <param name="Error">Why the announce was refused.</param>
/// <param name="Warnings">Things quietly fixed up, handed back so the operator hears about them.</param>
public sealed record AnnounceResult(RegisteredServer? Server, string? Error, string[] Warnings);

/// <summary>
/// Turns an announce into a listing, or says why it cannot.
///
/// Anything on the public internet can open this socket, so nothing in the
/// announce is trusted: strings are bounded before they reach a browser,
/// numbers are clamped to what the relay protocol can actually represent, and
/// the address is the one the connection came from unless the relay had a
/// specific reason to override it.
///
/// The distinction that matters here is refuse-versus-fix-up. A server with no
/// name or no port cannot be listed at all. A server with a fourth tag can --
/// dropping the tag and saying so beats hiding an otherwise healthy server
/// from the browser over a label, which is what the old Python service did.
/// </summary>
internal static class AnnounceValidator
{
	/// <summary>
	/// Tags a server may advertise. Fixed rather than free text so the
	/// launcher's filter has a known set to offer, and so the browser cannot
	/// be used to publish arbitrary strings. Matches the list the old Python
	/// service seeded its tag table with.
	/// </summary>
	public static readonly string[] AllowedTags = ["PvP", "PvE", "RP", "Hardcore", "Friendly", "Modded"];

	public const int MaxTags = 3;

	private const int MaxNameLength = 64;
	private const int MaxMapNameLength = 64;
	private const int MaxDescriptionLength = 500;
	private const int MaxVersionLength = 32;
	private const int MaxAddressLength = 253;

	/// <summary>
	/// Defensive public-listing cap. Ghost ids are wider, but this keeps bogus
	/// announcements from advertising impractical player counts.
	/// </summary>
	private const int MaxPlayerLimit = 255;

	public static AnnounceResult Build(ServerAnnounce announce, string observedAddress, string id, DateTimeOffset now)
	{
		var warnings = new List<string>();

		var name = Clean(announce.Name);
		if (name.Length == 0)
			return Refused("name is required");

		if (name.Length > MaxNameLength)
		{
			name = name[..MaxNameLength];
			warnings.Add($"name was truncated to {MaxNameLength} characters");
		}

		if (announce.Port is < 1 or > 65535)
			return Refused("port must be between 1 and 65535");

		var address = observedAddress;
		var advertised = Clean(announce.Address);
		if (advertised.Length > 0)
		{
			if (advertised.Length > MaxAddressLength || advertised.Any(c => char.IsWhiteSpace(c) || c == '/' || c == ':'))
			{
				// An IPv6 literal would legitimately contain colons, but a
				// relay that has one can send it via the connection itself;
				// what this rejects is a URL, a host:port pair, or anything
				// else that would be pasted into a listing unchecked.
				warnings.Add("address was ignored: it is not a plain hostname or IPv4 address");
			}
			else
			{
				address = advertised;
			}
		}

		if (address.Length == 0)
			return Refused("address could not be determined from the connection and none was supplied");

		var infoPort = announce.InfoPort;
		if (infoPort is < 0 or > 65535)
		{
			warnings.Add("infoPort was ignored: it is not a valid port");
			infoPort = 0;
		}

		var mapName = Clean(announce.MapName);
		if (mapName.Length > MaxMapNameLength)
		{
			mapName = mapName[..MaxMapNameLength];
			warnings.Add($"mapName was truncated to {MaxMapNameLength} characters");
		}

		var maxPlayers = Math.Clamp(announce.MaxPlayers, 0, MaxPlayerLimit);
		if (maxPlayers != announce.MaxPlayers)
			warnings.Add($"maxPlayers was clamped to the public listing limit of {MaxPlayerLimit}");

		var players = Math.Clamp(announce.Players, 0, maxPlayers);

		var description = Clean(announce.Description);
		if (description.Length > MaxDescriptionLength)
		{
			description = description[..MaxDescriptionLength];
			warnings.Add($"description was truncated to {MaxDescriptionLength} characters");
		}

		var releaseVersion = Clean(announce.ReleaseVersion);
		if (releaseVersion.Length > MaxVersionLength)
			releaseVersion = releaseVersion[..MaxVersionLength];

		var tags = SelectTags(announce.Tags, warnings);

		return new AnnounceResult(new RegisteredServer
		{
			Id              = id,
			Address         = address,
			Port            = announce.Port,
			InfoPort        = infoPort,
			Name            = name,
			ReleaseVersion  = releaseVersion,
			ProtocolVersion = announce.ProtocolVersion,
			MapName         = mapName,
			Players         = players,
			MaxPlayers      = maxPlayers,
			Tags            = tags,
			Description     = description.Length == 0 ? null : description,
			OnlineSince     = now,
			LastUpdate      = now,
		}, null, warnings.ToArray());
	}

	/// <summary>
	/// Bounds an update the same way <see cref="Build"/> bounds the announce
	/// it amends. An update arrives on an already-accepted connection, but
	/// that only means the sender got its first message right -- the numbers
	/// in this one are no more trustworthy than the ones in that one.
	/// </summary>
	public static ServerUpdate CleanUpdate(ServerUpdate update)
	{
		var mapName = Clean(update.MapName);
		var maxPlayers = Math.Clamp(update.MaxPlayers, 0, MaxPlayerLimit);

		return new ServerUpdate
		{
			MapName    = mapName.Length > MaxMapNameLength ? mapName[..MaxMapNameLength] : mapName,
			MaxPlayers = maxPlayers,
			Players    = Math.Clamp(update.Players, 0, maxPlayers),
		};
	}

	/// <summary>
	/// The address a listing is published under, as the master sees it.
	///
	/// A relay on the same machine arrives as "::ffff:127.0.0.1" -- an IPv4
	/// address wearing an IPv6 shape -- which nothing downstream would connect
	/// to successfully, so it is folded back to its IPv4 form.
	/// </summary>
	public static string ObservedAddress(IPAddress? remote)
	{
		if (remote is null)
			return "";

		return remote.IsIPv4MappedToIPv6 ? remote.MapToIPv4().ToString() : remote.ToString();
	}

	private static string[] SelectTags(string[]? tags, List<string> warnings)
	{
		if (tags is null || tags.Length == 0)
			return [];

		var selected = new List<string>(MaxTags);

		foreach (var raw in tags)
		{
			var match = AllowedTags.FirstOrDefault(t => t.Equals(Clean(raw), StringComparison.OrdinalIgnoreCase));

			if (match is null)
			{
				warnings.Add($"tag \"{Clean(raw)}\" was dropped; allowed tags are {string.Join(", ", AllowedTags)}");
				continue;
			}

			if (selected.Contains(match))
				continue;

			if (selected.Count == MaxTags)
			{
				warnings.Add($"tag \"{match}\" was dropped; at most {MaxTags} tags are listed");
				continue;
			}

			selected.Add(match);
		}

		return selected.ToArray();
	}

	private static string Clean(string? value) => value?.Trim() ?? "";

	private static AnnounceResult Refused(string error) => new(null, error, []);
}
