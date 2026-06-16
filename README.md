# Unity Native Dialog Plugin

A lightweight Unity plugin for displaying native iOS and Android dialog boxes with full hyperlink support. Dialogs use platform-native styling and cannot be dismissed by tapping outside.

## Install via UPM

1. Open the Package Manager Window.
2. Click `+` and select "Add package from git URL".
3. Paste:
`https://github.com/asus4/UnityNativeDialogPlugin.git?path=/Packages/com.github.asus4.nativedialog#v1.2.0`

## Usage

```csharp
using NativeDialog;
```

### Submit dialog (one button)

```csharp
DialogManager.ShowSubmit("Operation completed!", result =>
{
    Debug.Log("Dialog closed");
});
```

### Select dialog (OK / Cancel)

```csharp
DialogManager.ShowSelect("Are you sure?", result =>
{
    if (result) Debug.Log("Confirmed");
    else Debug.Log("Cancelled");
});
```

### With title

```csharp
DialogManager.ShowSubmit("Notice", "Something happened.", result => { });

DialogManager.ShowSelect("Confirm", "Do you want to proceed?", result => { });
```

### With tappable hyperlinks

Pass a plain-text `message` and a `DialogLink[]`. Each `Text` value must appear verbatim in the message — the link is injected automatically. Works on Android, iOS, and the Unity Editor.

```csharp
DialogManager.ShowSubmit(
    "Privacy Notice",
    "Please read our Privacy Policy and Terms of Service before continuing.",
    new DialogLink[]
    {
        new DialogLink { Text = "Privacy Policy",   Url = "https://example.com/privacy" },
        new DialogLink { Text = "Terms of Service", Url = "https://example.com/terms" },
    },
    result => { }
);
```

### Custom button labels

```csharp
DialogManager.SetLabel(decide: "Yes", cancel: "No", close: "OK");
```

### Programmatic dismiss

```csharp
int id = DialogManager.ShowSelect("Wait...", result => { });
DialogManager.Dismiss(id); // closes the dialog and fires callback with false
```

## Screenshots

### Android

https://github.com/user-attachments/assets/390e011a-7b3e-4128-8fd6-369c98a35054

### iOS

https://github.com/user-attachments/assets/4760a655-3fbf-4781-a084-6848f53da53c

### Editor Fallback

![Editor Fallback](https://github.com/user-attachments/assets/3fdb094d-397e-4af7-92e9-8ca75d323f50)

## 📄 License

MIT — see [LICENSE](LICENSE).
