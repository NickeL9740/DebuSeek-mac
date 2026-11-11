import SwiftUI

// MARK: - Chat View

struct ChatView: View {
    @EnvironmentObject var petController: PetController
    @EnvironmentObject var chatHistory: ChatHistoryManager
    
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "fish.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                Text("与 \(ConfigManager.shared.config.pet.name) 聊天")
                    .font(.headline)
                Spacer()
                Button(action: { clearHistory() }) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空聊天记录")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chatHistory.messages) { message in
                            Group {
                                if message.role == .systemNote {
                                    Text(message.content)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 4)
                                } else {
                                    MessageBubble(message: message)
                                }
                            }
                            .id(message.id)
                        }
                        
                        if isSending {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("大肥鱼正在思考...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding()
                            .id("loading")
                        }
                    }
                    .padding()
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: chatHistory.messages.count) { _ in
                    if let lastMessage = chatHistory.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isSending) { sending in
                    if sending {
                        withAnimation {
                            proxy.scrollTo("loading", anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            // Input
            HStack(spacing: 8) {
                TextField("输入消息...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .lineLimit(1...5)
                    .onSubmit {
                        sendMessage()
                    }
                
                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 380, minHeight: 450)
        .onAppear {
            isInputFocused = true
        }
    }
    
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        
        inputText = ""
        isSending = true
        
        Task {
            await petController.sendChatMessage(text)
            await MainActor.run {
                isSending = false
                isInputFocused = true
            }
        }
    }
    
    private func clearHistory() {
        chatHistory.clearHistory()
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    
    var isFromUser: Bool {
        message.role == .user
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isFromUser {
                Spacer(minLength: 60)
            }
            
            VStack(alignment: isFromUser ? .trailing : .leading, spacing: 4) {
                // Avatar/Name
                if !isFromUser {
                    HStack(spacing: 4) {
                        Image(systemName: "fish.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(ConfigManager.shared.config.pet.name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Message content
                Text(message.content)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isFromUser ? Color.accentColor : Color(NSColor.controlBackgroundColor)
                    )
                    .foregroundColor(isFromUser ? .white : .primary)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 18)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.gray.opacity(0.1), lineWidth: 0.5)
                    )
                
                // Time
                Text(formatTime(message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
            
            if !isFromUser {
                Spacer(minLength: 60)
            }
        }
        .padding(.horizontal, 8)
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Quick Chat Popover (for menu bar)

struct QuickChatView: View {
    @EnvironmentObject var petController: PetController
    @EnvironmentObject var chatHistory: ChatHistoryManager
    
    @State private var inputText: String = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Recent messages (last 5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chatHistory.messages.suffix(5)) { message in
                        QuickMessageRow(message: message)
                    }
                }
                .padding()
            }
            .frame(maxHeight: 200)
            
            Divider()
            
            // Input
            HStack(spacing: 8) {
                TextField("跟大肥鱼说句话...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { sendQuickMessage() }
                
                Button(action: sendQuickMessage) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 320)
        .onAppear { isFocused = true }
    }
    
    private func sendQuickMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        inputText = ""
        
        Task {
            await petController.sendChatMessage(text)
        }
    }
}

struct QuickMessageRow: View {
    let message: ChatMessage
    var isFromUser: Bool { message.role == .user }
    
    var body: some View {
        HStack {
            if isFromUser { Spacer() }
            
            Text(message.content)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isFromUser ? Color.accentColor.opacity(0.8) : Color(NSColor.controlBackgroundColor))
                .foregroundColor(isFromUser ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            
            if !isFromUser { Spacer() }
        }
        .padding(.horizontal, 8)
    }
}