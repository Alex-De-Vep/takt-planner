using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;

namespace Takt.Windows.Controls;

// Preserve an invisible hit target while providing the native resize pointer.
public sealed class ResizeCursorGrid : Grid
{
    private InputSystemCursor? cursor;
    public ResizeCursorGrid()
    {
        Loaded += (_, _) => { cursor ??= InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast); ProtectedCursor = cursor; };
        Unloaded += (_, _) => { ProtectedCursor = null; cursor?.Dispose(); cursor = null; };
    }
}
