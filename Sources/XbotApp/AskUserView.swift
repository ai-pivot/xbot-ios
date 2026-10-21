import SwiftUI

struct AskUserView: View {
    let prompt: AskPrompt
    let vm: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [Int: Set<String>] = [:]
    @State private var other: [Int: String] = [:]
    @State private var submitting = false

    private var answers: [String: String] {
        var result: [String: String] = [:]
        for (i, question) in prompt.questions.enumerated() {
            let free = other[i, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            let choices = question.options.filter { selected[i, default: []].contains($0) }.joined(separator: "、")
            result[String(i + 1)] = free.isEmpty ? choices : free
        }
        return result
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { Label("你的回答会帮助 Agent 继续完成任务。", systemImage: "hand.raised").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(Array(prompt.questions.enumerated()), id: \.offset) { index, question in
                    Section {
                        ForEach(question.options, id: \.self) { option in
                            Button {
                                if question.multiple {
                                    if selected[index, default: []].contains(option) { selected[index, default: []].remove(option) }
                                    else { selected[index, default: []].insert(option) }
                                } else { selected[index] = [option]; other[index] = "" }
                            } label: {
                                HStack { Text(option).foregroundStyle(.primary); Spacer(); Image(systemName: selected[index, default: []].contains(option) ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.accent) }
                            }
                        }
                        if question.allowOther || question.options.isEmpty {
                            TextField("直接回答…", text: Binding(get: { other[index, default: ""] }, set: { other[index] = $0 }), axis: .vertical).lineLimit(2...6)
                        }
                    } header: { Text(question.question) } footer: { if question.multiple { Text("可选择多项") } }
                }
                if let error = vm.error { Section { ErrorBanner(text: error) } }
                Section { Button("取消本轮", role: .destructive) { submit(cancelled: true) }.disabled(submitting) }
            }
            .navigationTitle("需要你的回答").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("稍后") { dismiss() }.disabled(submitting) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") { submit(cancelled: false) }.fontWeight(.semibold)
                        .disabled(submitting || answers.values.contains(where: \.isEmpty))
                }
            }
            .interactiveDismissDisabled(submitting)
        }
    }
    private func submit(cancelled: Bool) {
        submitting = true
        Task { let success = await vm.answer(cancelled ? [:] : answers, cancelled: cancelled); submitting = false; if success { dismiss() } }
    }
}
