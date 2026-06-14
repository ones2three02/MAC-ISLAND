import SwiftUI
import OpenIslandCore
import Observation
import UserNotifications

@MainActor
@Observable
class TimerModule: IslandModule {
    let id = "timer"
    
    enum TimerStatus {
        case stopped
        case running
        case paused
        case justFinished
    }
    
    enum FocusMode: CaseIterable {
        case work
        case shortBreak
        case longBreak
        
        var displayName: String {
            switch self {
            case .work: return "专注工作 💻"
            case .shortBreak: return "短时休息 ☕️"
            case .longBreak: return "长时休息 🌴"
            }
        }
        
        var themeColor: Color {
            switch self {
            case .work: return Color(red: 255/255, green: 90/255, blue: 95/255) // 番茄红色
            case .shortBreak: return Color(red: 46/255, green: 204/255, blue: 113/255) // 薄荷绿色
            case .longBreak: return Color(red: 52/255, green: 152/255, blue: 219/255) // 天空蓝色
            }
        }
        
        var iconName: String {
            switch self {
            case .work: return "hourglass.badge.plus"
            case .shortBreak: return "cup.and.saucer.fill"
            case .longBreak: return "leaf.fill"
            }
        }
    }
    
    var status: TimerStatus = .stopped
    var focusMode: FocusMode = .work
    var completedTomatoes: Int = 0
    var timeRemaining: TimeInterval = 25 * 60
    var totalDuration: TimeInterval = 25 * 60
    var customDuration: TimeInterval = 25 * 60
    
    private var internalTimer: Timer?
    private var finishDisplayTicks = 0
    
    var priority: IslandModulePriority {
        switch status {
        case .stopped, .paused:
            return .low
        case .running:
            return .medium
        case .justFinished:
            return .critical
        }
    }
    
    func leftPillView() -> AnyView {
        let isRunning = status == .running
        let systemName = isRunning ? focusMode.iconName : "hourglass"
        let color = isRunning ? focusMode.themeColor : Color.gray
        return AnyView(
            Image(systemName: systemName)
                .font(.system(size: 9))
                .foregroundStyle(color)
        )
    }
    
    func rightPillView() -> AnyView {
        let isRunning = status == .running
        let color = isRunning ? focusMode.themeColor : Color.gray
        return AnyView(
            Text(formatTime(timeRemaining))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        )
    }
    
    func expandedView() -> AnyView {
        AnyView(
            TimerExpandedView(module: self)
        )
    }
    
    func onActivate() {
        // 请求本地推送通知权限
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    func onDeactivate() {
        if status == .justFinished {
            status = .stopped
        }
    }
    
    func selectMode(_ mode: FocusMode) {
        guard status == .stopped || status == .justFinished else { return }
        focusMode = mode
        switch mode {
        case .work:
            customDuration = 25 * 60
        case .shortBreak:
            customDuration = 5 * 60
        case .longBreak:
            customDuration = 15 * 60
        }
        timeRemaining = customDuration
        totalDuration = customDuration
    }
    
    func adjustDuration(by offset: TimeInterval) {
        guard status == .stopped || status == .justFinished else { return }
        let newDuration = customDuration + offset
        customDuration = max(60, min(120 * 60, newDuration)) // 1分钟至120分钟
        timeRemaining = customDuration
        totalDuration = customDuration
    }
    
    func startTimer(duration: TimeInterval) {
        stopTimer()
        totalDuration = duration
        timeRemaining = duration
        status = .running
        
        internalTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }
    
    func pauseTimer() {
        if status == .running {
            internalTimer?.invalidate()
            internalTimer = nil
            status = .paused
        }
    }
    
    func resumeTimer() {
        if status == .paused {
            status = .running
            internalTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }
        }
    }
    
    func stopTimer() {
        internalTimer?.invalidate()
        internalTimer = nil
        status = .stopped
        timeRemaining = customDuration
        totalDuration = customDuration
    }
    
    private func tick() {
        if timeRemaining > 1 {
            timeRemaining -= 1
        } else {
            // 倒计时结束
            let finishedMode = focusMode
            stopTimer()
            status = .justFinished
            finishDisplayTicks = 8 // 展示 8 秒
            
            if finishedMode == .work {
                completedTomatoes += 1
            }
            
            // 发送本地通知与警报
            sendLocalNotification(for: finishedMode)
            NSSound.beep()
            
            // 倒计时 8 秒自动复原
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                nonisolated(unsafe) let unsafeTimer = timer
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        unsafeTimer.invalidate()
                        return
                    }
                    if self.finishDisplayTicks > 0 {
                        self.finishDisplayTicks -= 1
                    } else {
                        unsafeTimer.invalidate()
                        if self.status == .justFinished {
                            self.status = .stopped
                            self.timeRemaining = self.customDuration
                        }
                    }
                }
            }
        }
    }
    
    private func sendLocalNotification(for mode: FocusMode) {
        let content = UNMutableNotificationContent()
        switch mode {
        case .work:
            content.title = "专注完成！🍅"
            content.body = "恭喜！您已成功跑完一轮专注番茄钟。请起水活动活动，开启休息吧！☕️"
        case .shortBreak, .longBreak:
            content.title = "休息结束！🔔"
            content.body = "休息完毕，精力已回满。准备好开启新一轮的专注挑战了吗？💻"
        }
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: "timer.finished.\(Date().timeIntervalSince1970)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
    
    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Timer Expanded View

struct TimerExpandedView: View {
    let module: TimerModule
    
    var body: some View {
        VStack(spacing: 8) {
            // Header with tomato count
            HStack {
                Text("FOCUS TIMER")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                
                Spacer()
                
                if module.completedTomatoes > 0 {
                    HStack(spacing: 2) {
                        Text("今日成果:")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(String(repeating: "🍅", count: min(5, module.completedTomatoes)))
                            .font(.system(size: 10))
                        if module.completedTomatoes > 5 {
                            Text("×\(module.completedTomatoes)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(TimerModule.FocusMode.work.themeColor)
                        }
                    }
                } else {
                    Text("开始你今天的首个番茄吧 🍅")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 4)
            
            HStack(spacing: 12) {
                // Circular Timer Display
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.06), lineWidth: 4)
                    
                    if module.totalDuration > 0 {
                        Circle()
                            .trim(from: 0.0, to: CGFloat(module.timeRemaining / module.totalDuration))
                            .stroke(
                                module.focusMode.themeColor,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .shadow(color: module.focusMode.themeColor.opacity(module.status == .running ? 0.4 : 0.0), radius: 3)
                            .animation(.linear(duration: 1.0), value: module.timeRemaining)
                    }
                    
                    if module.status == .justFinished {
                        Text("DONE!")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(red: 46/255, green: 204/255, blue: 113/255))
                    } else {
                        Text(formatTimeFull(module.timeRemaining))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 54, height: 54)
                
                // Controls Column
                VStack(spacing: 5) {
                    if module.status == .stopped || module.status == .justFinished {
                        // Focus Mode Presets
                        HStack(spacing: 4) {
                            ForEach(TimerModule.FocusMode.allCases, id: \.self) { mode in
                                let isSelected = module.focusMode == mode
                                Button {
                                    withAnimation(.spring(response: 0.24, dampingFraction: 0.8)) {
                                        module.selectMode(mode)
                                    }
                                } label: {
                                    Text(mode == .work ? "工作" : (mode == .shortBreak ? "短休" : "长休"))
                                        .font(.system(size: 9, weight: isSelected ? .bold : .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3.5)
                                        .foregroundStyle(isSelected ? .white : .white.opacity(0.45))
                                        .background(isSelected ? mode.themeColor.opacity(0.20) : Color.white.opacity(0.04), in: Capsule())
                                        .overlay(
                                            Capsule()
                                                .stroke(isSelected ? mode.themeColor.opacity(0.35) : Color.clear, lineWidth: 0.5)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                        // Custom Adjuster & Start
                        HStack(spacing: 4) {
                            // Micro adjuster
                            HStack(spacing: 2) {
                                Button {
                                    module.adjustDuration(by: -60)
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 8, weight: .bold))
                                        .frame(width: 16, height: 16)
                                        .background(Color.white.opacity(0.06), in: Circle())
                                }
                                .buttonStyle(.plain)
                                
                                Text("\(Int(module.customDuration / 60))m")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .frame(width: 28, alignment: .center)
                                
                                Button {
                                    module.adjustDuration(by: 60)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 8, weight: .bold))
                                        .frame(width: 16, height: 16)
                                        .background(Color.white.opacity(0.06), in: Circle())
                                }
                                .buttonStyle(.plain)
                            }
                            
                            Spacer(minLength: 2)
                            
                            // Start Button
                            Button {
                                module.startTimer(duration: module.customDuration)
                            } label: {
                                Text(module.focusMode == .work ? "开始工作" : "开始休息")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4.5)
                                    .background(module.focusMode.themeColor, in: RoundedRectangle(cornerRadius: 5))
                                    .shadow(color: module.focusMode.themeColor.opacity(0.3), radius: 2, y: 1)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        // Running / Paused State Controls
                        HStack {
                            Text(module.focusMode.displayName)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(module.focusMode.themeColor)
                            
                            Text(module.status == .paused ? "(已暂停)" : "(计时中)")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.4))
                            
                            Spacer()
                        }
                        
                        HStack(spacing: 8) {
                            if module.status == .running {
                                controlButton(title: "暂停", icon: "pause.fill", color: .yellow) {
                                    module.pauseTimer()
                                }
                            } else {
                                controlButton(title: "继续", icon: "play.fill", color: .green) {
                                    module.resumeTimer()
                                }
                            }
                            
                            controlButton(title: "重置", icon: "arrow.clockwise", color: .red) {
                                module.stopTimer()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.04), lineWidth: 0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    
    private func controlButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text(title)
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
    
    private func formatTimeFull(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
