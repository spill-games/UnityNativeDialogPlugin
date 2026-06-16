#if UNITY_EDITOR
using System.Collections.Generic;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEngine;

namespace NativeDialog
{
    /// <summary>
    /// Editor-specific implementation of native dialogs.
    /// Prefers the structured DialogLink[] API for inline clickable links without any HTML parsing.
    /// Falls back to HTML anchor-tag parsing for legacy callers that embed markup in the message string.
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
            EditorApplication.delayCall += () => ShowSelectInternal(id, null, message, null);
            return id;
        }

        public int ShowSelect(string title, string message)
        {
            int id = ++currentId;
            EditorApplication.delayCall += () => ShowSelectInternal(id, title, message, null);
            return id;
        }

        public int ShowSelect(string title, string message, DialogLink[] links)
        {
            int id = ++currentId;
            EditorApplication.delayCall += () => ShowSelectInternal(id, title, message, links);
            return id;
        }

        public int ShowSubmit(string message)
        {
            int id = ++currentId;
            EditorApplication.delayCall += () => ShowSubmitInternal(id, null, message, null);
            return id;
        }

        public int ShowSubmit(string title, string message)
        {
            int id = ++currentId;
            EditorApplication.delayCall += () => ShowSubmitInternal(id, title, message, null);
            return id;
        }

        public int ShowSubmit(string title, string message, DialogLink[] links)
        {
            int id = ++currentId;
            EditorApplication.delayCall += () => ShowSubmitInternal(id, title, message, links);
            return id;
        }

        public void Dismiss(int id)
        {
            Debug.LogWarning($"Dismiss is not supported in Editor mode. ID: {id}");
            pendingDialogs.Remove(id);
        }

        private void ShowSelectInternal(int id, string title, string message, DialogLink[] links)
        {
            if (!pendingDialogs.ContainsKey(id))
            {
                pendingDialogs[id] = true;
            }
            else if (!pendingDialogs[id])
            {
                return;
            }

            string displayText;
            DialogLink[] resolvedLinks = ResolveLinks(message, links, out displayText);
            bool result;

            if (resolvedLinks.Length > 0)
            {
                result = NativeDialogEditorWindow.ShowSelectDialog(title, displayText, resolvedLinks, decideLabel, cancelLabel);
            }
            else
            {
                result = EditorUtility.DisplayDialog(title ?? string.Empty, displayText, decideLabel, cancelLabel);
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

        private void ShowSubmitInternal(int id, string title, string message, DialogLink[] links)
        {
            if (!pendingDialogs.ContainsKey(id))
            {
                pendingDialogs[id] = true;
            }
            else if (!pendingDialogs[id])
            {
                return;
            }

            string displayText;
            DialogLink[] resolvedLinks = ResolveLinks(message, links, out displayText);

            if (resolvedLinks.Length > 0)
            {
                NativeDialogEditorWindow.ShowSubmitDialog(title, displayText, resolvedLinks, closeLabel);
            }
            else
            {
                EditorUtility.DisplayDialog(title ?? string.Empty, displayText, closeLabel);
            }

            if (pendingDialogs.ContainsKey(id))
            {
                pendingDialogs.Remove(id);
                receiver?.OnSubmit(id.ToString());
            }
        }

        // When links[] is provided (new structured API), use them and treat message as plain text.
        // When links[] is null (legacy API), attempt to parse HTML anchor tags from the message string.
        private static DialogLink[] ResolveLinks(string message, DialogLink[] links, out string displayText)
        {
            if (links != null)
            {
                displayText = message;
                return links;
            }

            var parsed = HtmlLinkParser.ParseLinks(message);
            if (parsed.Count == 0)
            {
                displayText = message;
                return new DialogLink[0];
            }

            displayText = HtmlLinkParser.StripHtml(message);
            var result = new DialogLink[parsed.Count];
            for (int i = 0; i < parsed.Count; i++)
            {
                result[i] = new DialogLink { Text = parsed[i].Text, Url = parsed[i].Url };
            }
            return result;
        }
    }

    /// <summary>
    /// Utility for parsing and stripping HTML anchor tags from legacy message strings.
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
    /// Modal editor window that renders a plain-text message with inline clickable hyperlinks.
    /// Uses a custom IMGUI flow-layout renderer: link text is shown inline in blue with an underline
    /// and a link cursor, and clicking it opens the URL in the system browser.
    /// </summary>
    internal sealed class NativeDialogEditorWindow : EditorWindow
    {
        private string _message;
        private DialogLink[] _links;
        private List<FlowToken> _tokens;
        private string _okLabel;
        private string _cancelLabel; // null = submit dialog (single button)
        private bool? _result;

        private float _lastKnownWidth = -1f;
        private float _cachedContentHeight;

        private GUIStyle _normalStyle;
        private GUIStyle _linkStyle;

        // ── Public factory methods ─────────────────────────────────────────────

        /// <summary>
        /// Shows a modal select dialog with inline clickable hyperlinks.
        /// Returns true if OK was pressed, false otherwise.
        /// </summary>
        public static bool ShowSelectDialog(
            string title,
            string plainText,
            DialogLink[] links,
            string okLabel,
            string cancelLabel)
        {
            var window = CreateInstance<NativeDialogEditorWindow>();
            window.titleContent = new GUIContent(string.IsNullOrEmpty(title) ? "Dialog" : title);
            window._message = plainText ?? string.Empty;
            window._links = links;
            window._okLabel = okLabel;
            window._cancelLabel = cancelLabel;
            window.minSize = new Vector2(360f, 180f);
            window.maxSize = new Vector2(480f, 560f);
            window.ShowModalUtility();
            return window._result ?? false;
        }

        /// <summary>
        /// Shows a modal submit dialog with inline clickable hyperlinks (single close button).
        /// </summary>
        public static void ShowSubmitDialog(
            string title,
            string plainText,
            DialogLink[] links,
            string closeLabel)
        {
            var window = CreateInstance<NativeDialogEditorWindow>();
            window.titleContent = new GUIContent(string.IsNullOrEmpty(title) ? "Dialog" : title);
            window._message = plainText ?? string.Empty;
            window._links = links;
            window._okLabel = closeLabel;
            window._cancelLabel = null;
            window.minSize = new Vector2(360f, 180f);
            window.maxSize = new Vector2(480f, 560f);
            window.ShowModalUtility();
        }

        // ── EditorWindow lifecycle ─────────────────────────────────────────────

        private void OnDestroy()
        {
            // Treat window closure without a button press as cancel
            if (_result == null)
            {
                _result = false;
            }
        }

        private void OnGUI()
        {
            if (_tokens == null)
            {
                _tokens = BuildFlowTokens(_message, _links);
            }

            EnsureStyles();

            const float paddingH = 14f;
            float availableWidth = position.width - paddingH * 2f;
            float lineHeight = _normalStyle.lineHeight + 2f;

            if (Mathf.Abs(_lastKnownWidth - availableWidth) > 0.5f)
            {
                _cachedContentHeight = CalculateFlowHeight(_tokens, availableWidth, lineHeight);
                _lastKnownWidth = availableWidth;
                Repaint();
            }

            GUILayout.Space(12f);

            var flowRect = GUILayoutUtility.GetRect(availableWidth, _cachedContentHeight);
            flowRect.x = paddingH;
            flowRect.width = availableWidth;
            DrawFlowTokens(flowRect, _tokens, lineHeight);

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

            GUILayout.Space(8f);
            EditorGUILayout.EndHorizontal();
            GUILayout.Space(10f);
        }

        // ── Styles ─────────────────────────────────────────────────────────────

        private void EnsureStyles()
        {
            if (_normalStyle == null)
            {
                _normalStyle = new GUIStyle(EditorStyles.label)
                {
                    wordWrap = false,
                    richText = false
                };
            }

            if (_linkStyle == null)
            {
                _linkStyle = new GUIStyle(EditorStyles.label)
                {
                    wordWrap = false,
                    richText = false
                };
                var linkColor = EditorGUIUtility.isProSkin
                    ? new Color(0.40f, 0.69f, 1.0f)
                    : new Color(0.01f, 0.31f, 0.71f);
                _linkStyle.normal.textColor = linkColor;
                _linkStyle.hover.textColor = linkColor;
            }
        }

        // ── Token model ────────────────────────────────────────────────────────

        private struct FlowToken
        {
            public string Text;
            public string LinkUrl; // null = plain text; non-null = hyperlink
            public bool IsLink => LinkUrl != null;
            public bool IsNewline => Text == "\n";
        }

        private struct LinkPosition
        {
            public int Start;
            public int End;
            public string Url;
        }

        // Splits the message into word-level FlowTokens, tagging which words belong to hyperlinks.
        // Link text is located via IndexOf — no regex required.
        private static List<FlowToken> BuildFlowTokens(string message, DialogLink[] links)
        {
            var tokens = new List<FlowToken>();

            if (string.IsNullOrEmpty(message))
            {
                return tokens;
            }

            if (links == null || links.Length == 0)
            {
                TokenizeText(tokens, message, null);
                return tokens;
            }

            // Find the character position of each link text within the message
            var positions = new List<LinkPosition>();
            foreach (var link in links)
            {
                if (string.IsNullOrEmpty(link.Text) || string.IsNullOrEmpty(link.Url))
                {
                    continue;
                }
                int idx = message.IndexOf(link.Text, System.StringComparison.Ordinal);
                if (idx >= 0)
                {
                    positions.Add(new LinkPosition { Start = idx, End = idx + link.Text.Length, Url = link.Url });
                }
            }

            // Walk left-to-right through the message, emitting plain and link segments
            positions.Sort((a, b) => a.Start.CompareTo(b.Start));

            int cursor = 0;
            foreach (var pos in positions)
            {
                if (pos.Start > cursor)
                {
                    TokenizeText(tokens, message.Substring(cursor, pos.Start - cursor), null);
                }
                TokenizeText(tokens, message.Substring(pos.Start, pos.End - pos.Start), pos.Url);
                cursor = pos.End;
            }

            if (cursor < message.Length)
            {
                TokenizeText(tokens, message.Substring(cursor), null);
            }

            return tokens;
        }

        // Splits a text segment into word tokens.
        // Each token includes its trailing space so word spacing is preserved.
        // Newlines become standalone line-break tokens (Text == "\n").
        private static void TokenizeText(List<FlowToken> tokens, string text, string linkUrl)
        {
            if (string.IsNullOrEmpty(text))
            {
                return;
            }

            int start = 0;
            for (int i = 0; i < text.Length; i++)
            {
                char c = text[i];
                if (c == '\n')
                {
                    if (i > start)
                    {
                        tokens.Add(new FlowToken { Text = text.Substring(start, i - start), LinkUrl = linkUrl });
                    }
                    tokens.Add(new FlowToken { Text = "\n", LinkUrl = null });
                    start = i + 1;
                }
                else if (c == ' ')
                {
                    tokens.Add(new FlowToken { Text = text.Substring(start, i - start + 1), LinkUrl = linkUrl });
                    start = i + 1;
                }
            }

            if (start < text.Length)
            {
                tokens.Add(new FlowToken { Text = text.Substring(start), LinkUrl = linkUrl });
            }
        }

        // ── Flow layout ────────────────────────────────────────────────────────

        // Simulates the layout pass to determine the total pixel height needed.
        private float CalculateFlowHeight(List<FlowToken> tokens, float maxWidth, float lineHeight)
        {
            float x = 0f;
            int lines = 1;

            foreach (var token in tokens)
            {
                if (token.IsNewline)
                {
                    x = 0f;
                    lines++;
                    continue;
                }

                var style = token.IsLink ? _linkStyle : _normalStyle;
                float w = style.CalcSize(new GUIContent(token.Text)).x;

                if (x > 0f && x + w > maxWidth)
                {
                    x = 0f;
                    lines++;
                }

                x += w;
            }

            return lines * lineHeight + 4f;
        }

        // Renders tokens using a manual flow layout: left-to-right, wrapping at maxWidth.
        // Link tokens are drawn in the link color with an underline, and open their URL on click.
        private void DrawFlowTokens(Rect container, List<FlowToken> tokens, float lineHeight)
        {
            float x = 0f;
            float y = 0f;

            foreach (var token in tokens)
            {
                if (token.IsNewline)
                {
                    x = 0f;
                    y += lineHeight;
                    continue;
                }

                var style = token.IsLink ? _linkStyle : _normalStyle;
                var content = new GUIContent(token.Text);
                float tokenWidth = style.CalcSize(content).x;

                if (x > 0f && x + tokenWidth > container.width)
                {
                    x = 0f;
                    y += lineHeight;
                }

                var tokenRect = new Rect(container.x + x, container.y + y, tokenWidth, lineHeight);

                if (token.IsLink)
                {
                    EditorGUIUtility.AddCursorRect(tokenRect, MouseCursor.Link);
                    GUI.Label(tokenRect, content, _linkStyle);

                    if (Event.current.type == EventType.Repaint)
                    {
                        // Draw underline only under the non-whitespace portion of the token
                        string trimmed = token.Text.TrimEnd();
                        if (trimmed.Length > 0)
                        {
                            float underlineWidth = _linkStyle.CalcSize(new GUIContent(trimmed)).x;
                            EditorGUI.DrawRect(
                                new Rect(tokenRect.x, tokenRect.y + lineHeight - 2f, underlineWidth, 1f),
                                _linkStyle.normal.textColor
                            );
                        }
                    }

                    if (Event.current.type == EventType.MouseDown
                        && tokenRect.Contains(Event.current.mousePosition))
                    {
                        Application.OpenURL(token.LinkUrl);
                        Event.current.Use();
                    }
                }
                else
                {
                    GUI.Label(tokenRect, content, _normalStyle);
                }

                x += tokenWidth;
            }
        }
    }
}
#endif
