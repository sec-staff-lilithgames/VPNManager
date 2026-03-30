//
//  ShortcutsView.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 11/17/25.
//

import SwiftUI

private struct ShortcutItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let keyDescription: String
    let action: ShortcutAction
}

struct ShortcutsView: View {
    @State private var isExecuting: Bool = false
    @State private var executionResult: String = ""
    let onAction: (ShortcutAction) -> Void
    let onClose: () -> Void
    
    private let availableShortcuts: [ShortcutItem] = [
        ShortcutItem(title: "切换当前 VPN", keyDescription: "Control + A", action: .toggleCurrentVPN)
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("快捷操作")
                .font(.headline)
                .padding(.bottom, 5)
            
            List(availableShortcuts) { shortcut in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortcut.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("默认快捷键：\(shortcut.keyDescription)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Button("执行") {
                        executeShortcut(shortcut)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExecuting)
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 150, maxHeight: 200)
            
            if !executionResult.isEmpty {
                VStack(alignment: .leading) {
                    Text("执行结果:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text(executionResult)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(5)
            }
            
            HStack {
                Spacer()
                
                Button("关闭") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 300, maxWidth: 400, minHeight: 300, maxHeight: 500)
    }
    
    private func executeShortcut(_ shortcut: ShortcutItem) {
        isExecuting = true
        executionResult = ""

        onAction(shortcut.action)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            executionResult = "已触发“\(shortcut.title)”快捷操作。"
            isExecuting = false
        }
    }
}
