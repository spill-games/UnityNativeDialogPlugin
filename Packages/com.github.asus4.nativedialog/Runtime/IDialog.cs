namespace NativeDialog
{
    /// <summary>
    /// Represents a hyperlink that can be displayed within a native dialog message.
    /// Pass one or more of these alongside a plain-text message to the ShowSubmit/ShowSelect
    /// overloads that accept a links array — no HTML markup required.
    /// </summary>
    public struct DialogLink
    {
        /// <summary>The visible label for the hyperlink (must appear verbatim in the message string).</summary>
        public string Text;
        /// <summary>The URL to open when the link is tapped or clicked.</summary>
        public string Url;
    }

    /// <summary>
    /// Interface for platform-specific dialog implementations.
    /// Defines methods for showing native dialogs across different platforms.
    /// </summary>
    public interface IDialog : System.IDisposable
    {
        void SetLabel(string decide, string cancel, string close);
        int ShowSelect(string message);
        int ShowSelect(string title, string message);
        int ShowSelect(string title, string message, DialogLink[] links);
        int ShowSubmit(string message);
        int ShowSubmit(string title, string message);
        int ShowSubmit(string title, string message, DialogLink[] links);
        void Dismiss(int id);
    }
}
