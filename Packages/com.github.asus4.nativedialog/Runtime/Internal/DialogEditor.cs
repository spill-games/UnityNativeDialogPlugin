#if UNITY_EDITOR
using System.Collections.Generic;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEngine;

namespace NativeDialog
{
    /// <summary>
    /// Mock implementation of dialogs for Unity Editor.
    /// Uses a custom EditorWindow to support clickable hyperlinks when the message
    /// contains HTML anchor tags. Falls back to EditorUtility.DisplayDialog for plain text.
    /// </summary>
    internal sealed class DialogEditor : IDialog
    {
        private string decideLabel = "YES";
        private string cancelLabel = "NO";
        private string closeLabel = "CLOSE";
        private int currentId = 0;
        private IDialogReceiver receiver;
        private readonly Dictionary<int, bool> pendingDialogs = new Dictionary<int, bool>();

        public DialogEditor(IDialogReceiver receiver)
        {
            this.receiver = receiver;
        }

        public void Dispose()
        {
            pendingDialogs.Clear();
            receiver = null;
        }

        public void SetLabel(string decide, string cancel, string close)
        {
            decideLabel = decide;
            cancelLabel = cancel;
            closeLabel = close;
        }

        public int ShowSelect(string message)
        {
            int id = ++currentId;
            EditorApplication.delayCall += () => ShowSelectDialog(id, null, message);
            return id;
        }

        public int ShowSelect(string title, string message)
        {
            int id = ++currentId;
            EditorApplication.delayCall += () => ShowSelectDialog(id, title, message);
            return id;
        }

        public int ShowSubmit(string message)
        {
            int id = ++currentId;
            EditorApplication.delayCall += () => ShowSubmitDialog(id, null, message);
            return id;
        }

        public int ShowSubmit(string title, string message)
        {
            int id = ++currentId;
            EditorApplication.delayCall += () => ShowSubmitDialog(id, title, message);
            return id;
        }

        public void Dismiss(int id)
        {
            Debug.LogWarning($"Dismiss is not supported in Editor mode. ID: {id}");
            if (pendingDialogs.ContainsKey(id))
            {
                pendingDialogs.Remove(id);
            }
        }

        private void ShowSelectDialog(int id, string title, string message)
        {
            if (!pendingDialogs.ContainsKey(id))
            {
                pendingDialogs[id] = true;
            }
            else if (!pendingDialogs[id])
            {
                return;
            }

            var links = HtmlLinkParser.ParseLinks(message);
            bool result;

            if (links.Count > 0)
            {
                string plainText = HtmlLinkParser.StripHtml(message);
                result = NativeDialogEditorWindow.ShowSelectDialog(title, plainText, links, decideLabel, cancelLabel);
            }
            else
            {
                result = EditorUtility.DisplayDialog(title ?? string.Empty, message, decideLabel, cancelLabel);
            }

            if (pendingDialogs.ContainsKey(id))
            {
                pendingDialogs.Remove(id);
                if (result)
                {
                    receiver?.OnSubmit(id.ToString());
                }
                else
                {
                    receiver?.OnCancel(id.ToString());
                }
            }
        }

        private void ShowSubmitDialog(int id, string title, string message)
        {
            if (!pendingDialogs.ContainsKey(id))
            {
                pendingDialogs[id] = true;
            }
            else if (!pendingDialogs[id])
            {
                return;
            }

            var links = HtmlLinkParser.ParseLinks(message);

            if (links.Count > 0)
            {
                string plainText = HtmlLinkParser.StripHtml(message);
                NativeDialogEditorWindow.ShowSubmitDialog(title, plainText, links, closeLabel);
            }
            else
            {
                EditorUtility.DisplayDialog(title ?? string.Empty, message, closeLabel);
            }

            if (pendingDialogs.ContainsKey(id))
            {
                pendingDialogs.Remove(id);
                receiver?.OnSubmit(id.ToString());
            }
        }
    }

    /// <summary>
    /// Utility for parsing and stripping HTML anchor tags from dialog message strings.
    /// </summary>
    internal static class HtmlLinkParser
    {
        internal struct LinkSegment
        {
            public string Text;
            public string Url;
        }

        private static readonly Regex LinkRegex = new Regex(
            @"<a\s+href=""([^""]+)"">([^<]+)</a>",
            RegexOptions.IgnoreCase | RegexOptions.Compiled
        );

        public static List<LinkSegment> ParseLinks(string html)
        {
            var links = new List<LinkSegment>();
            foreach (Match match in LinkRegex.Matches(html))
            {
                links.Add(new LinkSegment { Url = match.Groups[1].Value, Text = match.Groups[2].Value });
            }
            return links;
        }

        public static string StripHtml(string html)
        {
            return Regex.Replace(html, @"<[^>]+>", string.Empty);
        }
    }

    /// <summary>
    /// Modal editor window used when a dialog message contains HTML hyperlinks.
    /// Renders plain text with clickable link buttons that open URLs in the browser.
    /// </summary>
    internal sealed class NativeDialogEditorWindow : EditorWindow
    {
        private string _message;
        private List<HtmlLinkParser.LinkSegment> _links;
        private string _okLabel;
        private string _cancelLabel; // null = submit dialog (no cancel button)
        private bool? _result;

        /// <summary>
        /// Shows a modal select dialog with clickable links and returns true if OK was pressed.
        /// </summary>
        public static bool ShowSelectDialog(string title, string plainText, List<HtmlLinkParser.LinkSegment> links, string okLabel, string cancelLabel)
        {
            var window = CreateInstance<NativeDialogEditorWindow>();
            window.titleContent = new GUIContent(string.IsNullOrEmpty(title) ? "Dialog" : title);
            window._message = plainText;
            window._links = links ?? new List<HtmlLinkParser.LinkSegment>();
            window._okLabel = okLabel;
            window._cancelLabel = cancelLabel;
            window.minSize = new Vector2(320, 160);
            window.maxSize = new Vector2(420, 500);
            window.ShowModalUtility();
            return window._result ?? false;
        }

        /// <summary>
        /// Shows a modal submit dialog with clickable links (single close button).
        /// </summary>
        public static void ShowSubmitDialog(string title, string plainText, List<HtmlLinkParser.LinkSegment> links, string closeLabel)
        {
            var window = CreateInstance<NativeDialogEditorWindow>();
            window.titleContent = new GUIContent(string.IsNullOrEmpty(title) ? "Dialog" : title);
            window._message = plainText;
            window._links = links ?? new List<HtmlLinkParser.LinkSegment>();
            window._okLabel = closeLabel;
            window._cancelLabel = null;
            window.minSize = new Vector2(320, 160);
            window.maxSize = new Vector2(420, 500);
            window.ShowModalUtility();
        }

        private void OnDestroy()
        {
            // Treat closing the window without clicking a button as cancel
            if (_result == null)
            {
                _result = false;
            }
        }

        private void OnGUI()
        {
            GUILayout.Space(12);

            EditorGUILayout.LabelField(_message ?? string.Empty, EditorStyles.wordWrappedLabel);

            if (_links != null && _links.Count > 0)
            {
                GUILayout.Space(6);
                EditorGUILayout.LabelField(string.Empty, GUI.skin.horizontalSlider);
                GUILayout.Space(2);

                foreach (var link in _links)
                {
                    EditorGUILayout.BeginHorizontal();
                    GUILayout.Space(8);
                    if (EditorGUILayout.LinkButton(link.Text))
                    {
                        Application.OpenURL(link.Url);
                    }
                    GUILayout.FlexibleSpace();
                    EditorGUILayout.EndHorizontal();
                }
            }

            GUILayout.FlexibleSpace();

            EditorGUILayout.BeginHorizontal();
            GUILayout.FlexibleSpace();

            if (_cancelLabel != null && GUILayout.Button(_cancelLabel, GUILayout.Width(90)))
            {
                _result = false;
                Close();
            }

            if (GUILayout.Button(_okLabel ?? "OK", GUILayout.Width(90)))
            {
                _result = true;
                Close();
            }

            GUILayout.Space(8);
            EditorGUILayout.EndHorizontal();
            GUILayout.Space(8);
        }
    }
}
#endif
