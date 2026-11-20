import SwiftUI

struct FolderDragPreview: View {
    let kind: FolderDragPayload.Kind

    var body: some View {
        Image(systemName: kind == .task ? "doc.text.fill" : "note.text")
            .font(.system(size: 30))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.gray)
            .frame(width: 40, height: 44)
    }
}
