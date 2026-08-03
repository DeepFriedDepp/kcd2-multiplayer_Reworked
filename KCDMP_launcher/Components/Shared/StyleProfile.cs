using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace KCDMP_launcher.Components.Shared
{
    /// <summary>
    /// WO-19: gained a real palette, pulled from the in-game dice overlay's
    /// own art direction (docs/WO-6-overlay-design.md SS2 -- aged parchment,
    /// oak, iron, candle-warm gold, tavern shadow) so the launcher and the
    /// in-game UI read as one product. Defaults here match wwwroot/css/site.css's
    /// `:root` block; Home.razor.cs pushes <see cref="ToCssVariables"/> over
    /// that default via JS interop on startup and on <see cref="Globals.OnStyleChanged"/>,
    /// so this class -- not the CSS file -- is the live source of truth.
    /// </summary>
    public class StyleProfile : BaseProfile
    {
        public string Id { get; set; } = Guid.NewGuid().ToString();

        public string ProfileName { get; set; } = string.Empty;
        public string FontFamily { get; set; } = "Libre Baskerville";
        public string SpecialFontFamily { get; set; } = "Cinzel";
        public int FontSize { get; set; } = 14;
        public int FontWeight { get; set; } = 400;
        public string FontColor { get; set; } = "#1e1e1e";

        public string ColorGold { get; set; } = "#D9AD4D";
        public string ColorGoldBright { get; set; } = "#FFDB73";
        public string ColorParchment { get; set; } = "#DBC9A1";
        public string ColorParchmentDim { get; set; } = "#C7B99A";
        public string ColorOak { get; set; } = "#573D24";
        public string ColorOakLit { get; set; } = "#856138";
        public string ColorIron { get; set; } = "#6B6963";
        public string ColorInk { get; set; } = "#211A12";
        public string ColorShadow { get; set; } = "#0F0D0A";
        public string ColorBlood { get; set; } = "#9E211C";
        public string ColorDangerBright { get; set; } = "#D6453D";
        public string ColorWarn { get; set; } = "#C2793D";
        public string ColorDim { get; set; } = "#615747";
        public string ColorMuted { get; set; } = "#A99B7E";
        public string ColorMutedDim { get; set; } = "#6B6355";
        public string ColorOnline { get; set; } = "#5FBF4A";
        public string ColorTrack { get; set; } = "#17120C";

        /// <summary>
        /// CSS custom-property name/value pairs for this profile. Applied to
        /// <c>document.documentElement</c> via the <c>applyKcdTheme</c> JS
        /// function (wwwroot/index.html), which just calls
        /// <c>style.setProperty</c> for each entry -- the shadow-rgb triple is
        /// derived here rather than stored, so a profile only ever has to
        /// carry one hex value per colour.
        /// </summary>
        public Dictionary<string, string> ToCssVariables() => new()
        {
            ["--kcd-gold"] = ColorGold,
            ["--kcd-gold-bright"] = ColorGoldBright,
            ["--kcd-parchment"] = ColorParchment,
            ["--kcd-parchment-dim"] = ColorParchmentDim,
            ["--kcd-oak"] = ColorOak,
            ["--kcd-oak-lit"] = ColorOakLit,
            ["--kcd-iron"] = ColorIron,
            ["--kcd-ink"] = ColorInk,
            ["--kcd-shadow"] = ColorShadow,
            ["--kcd-shadow-rgb"] = HexToRgbTriple(ColorShadow),
            ["--kcd-blood"] = ColorBlood,
            ["--kcd-danger-bright"] = ColorDangerBright,
            ["--kcd-warn"] = ColorWarn,
            ["--kcd-dim"] = ColorDim,
            ["--kcd-muted"] = ColorMuted,
            ["--kcd-muted-dim"] = ColorMutedDim,
            ["--kcd-online"] = ColorOnline,
            ["--kcd-track"] = ColorTrack,
            ["--kcd-font-family"] = $"'{FontFamily}', serif",
            ["--kcd-font-special"] = $"'{SpecialFontFamily}', serif",
        };

        private static string HexToRgbTriple(string hex)
        {
            hex = hex.TrimStart('#');
            byte r = Convert.ToByte(hex[..2], 16);
            byte g = Convert.ToByte(hex.Substring(2, 2), 16);
            byte b = Convert.ToByte(hex.Substring(4, 2), 16);
            return $"{r}, {g}, {b}";
        }

        public void SaveProfileToFile()
        {
            base.SaveProfileToFile(Globals.StylesProfilesDirectoryPath, $"{ProfileName}_{Id}");
        }
    }
}
