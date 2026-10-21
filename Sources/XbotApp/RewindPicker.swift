import SwiftUI

struct RewindPicker: View {
    let vm: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ChatTurn?
    @State private var confirming = false
    @State private var working = false
    var body: some View {
        NavigationStack {
            List {
                Section { Text("将删除目标消息之后的历史和迭代，并把原消息放回输入框。").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(vm.state.turns.filter { $0.historyID > 0 && !$0.user.isEmpty }) { turn in
                    Button { selected = turn } label: {
                        HStack { VStack(alignment: .leading, spacing: 5) { Text(turn.user).lineLimit(2).foregroundStyle(Color.primary); Text("Turn \(turn.id)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: selected?.id == turn.id ? "checkmark.circle.fill" : "circle") }
                    }
                }
                if vm.state.turns.allSatisfy({ $0.historyID <= 0 || $0.user.isEmpty }) { ContentUnavailableView("没有可回退的历史消息", systemImage: "clock.arrow.circlepath", description: Text("先重新同步，获取已保存的消息。")) }
                if let error = vm.error { ErrorBanner(text: error) }
            }.navigationTitle("回退到某条消息").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(working) }
                    ToolbarItem(placement: .confirmationAction) { Button("回退", role: .destructive) { confirming = true }.disabled(selected == nil || working) }
                }
                .confirmationDialog("回退后会移除后续历史，是否继续？", isPresented: $confirming, titleVisibility: .visible) {
                    Button("回退历史", role: .destructive) { if let turn = selected { working = true; Task { await vm.rewind(turn); working = false; if vm.error == nil { dismiss() } } } }
                }
                .interactiveDismissDisabled(working)
        }
    }
}
