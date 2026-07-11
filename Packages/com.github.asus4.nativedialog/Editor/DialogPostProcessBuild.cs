#if UNITY_IOS
using UnityEditor;
using UnityEditor.Callbacks;
using UnityEditor.iOS.Xcode;

namespace NativeDialog.Editor
{
    /// <summary>
    /// Links WebKit.framework into the generated Xcode project with the correct
    /// capitalization. The native dialog renders HTML messages through
    /// NSAttributedString's NSHTMLTextDocumentType importer (UNDialogManager.mm),
    /// which depends on WebKit. Adding the framework here guarantees the project
    /// reference always matches the on-disk framework name ("WebKit.framework")
    /// and prevents the "Webkit.framework" vs "WebKit.framework" case mismatch.
    /// </summary>
    public static class DialogPostProcessBuild
    {
        [PostProcessBuild(1000)]
        public static void OnPostProcessBuild(BuildTarget target, string pathToBuiltProject)
        {
            if (target != BuildTarget.iOS)
            {
                return;
            }

            string projectPath = PBXProject.GetPBXProjectPath(pathToBuiltProject);
            var project = new PBXProject();
            project.ReadFromFile(projectPath);

            // Native plugin code compiles into the UnityFramework target on
            // Unity 2019.3+, so the framework dependency belongs there.
            string targetGuid = project.GetUnityFrameworkTargetGuid();
            project.AddFrameworkToProject(targetGuid, "WebKit.framework", false);

            project.WriteToFile(projectPath);
        }
    }
}
#endif // UNITY_IOS
