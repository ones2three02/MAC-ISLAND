import SwiftUI
import OpenIslandCore
import Observation

#if canImport(Darwin)
import Darwin
#endif

@MainActor
@Observable
class SystemTelemetryModule: IslandModule {
    let id = "system_telemetry"
    
    // 该模块是系统常驻的底色模块，优先级为 low
    var priority: IslandModulePriority {
        return .low
    }
    
    var leftPillWidth: CGFloat { 48 }
    var rightPillWidth: CGFloat { 44 }
    
    var cpuUsage: Double = 0.0
    var memoryUsage: Double = 0.0
    var downloadSpeed: Double = 0.0
    var uploadSpeed: Double = 0.0
    
    var localIP: String = "127.0.0.1"
    var publicIP: String = "Loading..."
    var location: String = "Loading..."
    
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    
    var diskUsage: Double = 0.0
    var diskUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var cpuCores: Int = 1
    
    private let cpuMonitor = CpuMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let netMonitor = NetworkMonitor()
    private let diskMonitor = DiskMonitor()
    private var timer: Timer?
    private var isActive = false
    
    init() {
        // 获取 CPU 核心数
        var cores: uint32 = 0
        var size = MemoryLayout<uint32>.size
        if sysctlbyname("hw.ncpu", &cores, &size, nil, 0) == 0 {
            cpuCores = Int(cores)
        } else {
            cpuCores = 1
        }
        
        // 预热数据
        cpuUsage = cpuMonitor.getCpuUsage()
        
        let memDetails = memoryMonitor.getMemoryDetails()
        memoryUsage = memDetails.percentage
        memoryUsed = memDetails.used
        memoryTotal = memDetails.total
        
        let diskDetails = diskMonitor.getDiskUsage()
        diskUsage = diskDetails.percentage
        diskUsed = diskDetails.used
        diskTotal = diskDetails.total
        
        _ = netMonitor.getNetworkSpeed()
    }
    
    func leftPillView() -> AnyView {
        AnyView(
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text(String(format: "%.0f%%", cpuUsage))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: 48, alignment: .leading)
        )
    }
    
    func rightPillView() -> AnyView {
        AnyView(
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.blue)
                Text(formatSpeed(downloadSpeed))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: 44, alignment: .trailing)
        )
    }
    
    func expandedView() -> AnyView {
        AnyView(
            SystemTelemetryExpandedView(module: self)
        )
    }
    
    func onActivate() {
        guard !isActive else { return }
        isActive = true
        
        fetchNetworkInfo()
        
        // 启动高频 Timer
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }
    
    func onDeactivate() {
        isActive = false
        timer?.invalidate()
        timer = nil
    }
    
    private func tick() {
        cpuUsage = cpuMonitor.getCpuUsage()
        
        let memDetails = memoryMonitor.getMemoryDetails()
        memoryUsage = memDetails.percentage
        memoryUsed = memDetails.used
        memoryTotal = memDetails.total
        
        let diskDetails = diskMonitor.getDiskUsage()
        diskUsage = diskDetails.percentage
        diskUsed = diskDetails.used
        diskTotal = diskDetails.total
        
        let speeds = netMonitor.getNetworkSpeed()
        downloadSpeed = speeds.downloadSpeed
        uploadSpeed = speeds.uploadSpeed
    }
    
    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 {
            return String(format: "%.0fB", bytesPerSec)
        } else if bytesPerSec < 1024 * 1024 {
            return String(format: "%.1fK", bytesPerSec / 1024.0)
        } else {
            return String(format: "%.1fM", bytesPerSec / (1024.0 * 1024.0))
        }
    }
    
    private func getLocalIPAddress() -> String {
        var address: String = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return address
        }
        defer { freeifaddrs(ifaddr) }
        
        var candidates: [String: String] = [:]
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name != "lo0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        let ip = String(cString: &hostname)
                        if !ip.isEmpty && ip != "127.0.0.1" {
                            candidates[name] = ip
                        }
                    }
                }
            }
        }
        
        if let en0Ip = candidates["en0"] {
            address = en0Ip
        } else if let firstAlternative = candidates.keys.sorted().first, let ip = candidates[firstAlternative] {
            address = ip
        }
        return address
    }
    
    private func fetchNetworkInfo() {
        localIP = getLocalIPAddress()
        
        Task {
            do {
                // 通道 1: IPIP.NET (国内最稳定, 中文)
                guard let url = URL(string: "https://myip.ipip.net/json") else { return }
                let (data, _) = try await URLSession.shared.data(from: url)
                
                struct IPIPResponse: Codable {
                    let ret: String
                    let data: IPIPData
                }
                struct IPIPData: Codable {
                    let ip: String
                    let location: [String]
                }
                
                let response = try JSONDecoder().decode(IPIPResponse.self, from: data)
                
                await MainActor.run {
                    self.publicIP = response.data.ip
                    let locParts = response.data.location.prefix(3).filter { !$0.isEmpty }
                    var uniqueParts: [String] = []
                    for part in locParts {
                        if !uniqueParts.contains(part) {
                            uniqueParts.append(part)
                        }
                    }
                    self.location = uniqueParts.isEmpty ? "Unknown" : uniqueParts.joined(separator: " ")
                }
            } catch {
                await fetchNetworkInfoFallback1()
            }
        }
    }
    
    private func fetchNetworkInfoFallback1() async {
        do {
            // 通道 2: IP.SB (全球加速, 英文)
            guard let url = URL(string: "https://api.ip.sb/geoip") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            
            struct IPSBResponse: Codable {
                let ip: String
                let country: String?
                let region: String?
                let city: String?
            }
            
            let response = try JSONDecoder().decode(IPSBResponse.self, from: data)
            
            await MainActor.run {
                self.publicIP = response.ip
                let locParts = [response.country, response.region, response.city]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                var uniqueParts: [String] = []
                for part in locParts {
                    if !uniqueParts.contains(part) {
                        uniqueParts.append(part)
                    }
                }
                self.location = uniqueParts.isEmpty ? "Unknown" : uniqueParts.joined(separator: " ")
            }
        } catch {
            await fetchNetworkInfoFallback2()
        }
    }
    
    private func fetchNetworkInfoFallback2() async {
        do {
            // 通道 3: MYIP.LA (备用, 中文)
            guard let url = URL(string: "https://api.myip.la/cn?json") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            
            struct MyIPLaResponse: Codable {
                let ip: String
                let location: MyIPLaLocation
            }
            struct MyIPLaLocation: Codable {
                let country_name: String?
                let province: String?
                let city: String?
            }
            
            let response = try JSONDecoder().decode(MyIPLaResponse.self, from: data)
            
            await MainActor.run {
                self.publicIP = response.ip
                let locParts = [response.location.country_name, response.location.province, response.location.city]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                var uniqueParts: [String] = []
                for part in locParts {
                    if !uniqueParts.contains(part) {
                        uniqueParts.append(part)
                    }
                }
                self.location = uniqueParts.isEmpty ? "Unknown" : uniqueParts.joined(separator: " ")
            }
        } catch {
            await MainActor.run {
                self.publicIP = "Unknown"
                self.location = "Unknown"
            }
        }
    }
    
    // 格式化 Memory & Disk 大小
    var formattedMemoryUsed: String {
        formatGBPrecise(memoryUsed)
    }
    
    var formattedMemoryTotal: String {
        formatGB(memoryTotal)
    }
    
    var formattedDiskUsed: String {
        formatGBPrecise(diskUsed)
    }
    
    var formattedDiskTotal: String {
        formatGB(diskTotal)
    }
    
    private func formatGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1000 {
            return String(format: "%.0fT", gb / 1024.0)
        }
        return String(format: "%.0fG", gb)
    }
    
    private func formatGBPrecise(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1000 {
            return String(format: "%.1fT", gb / 1024.0)
        }
        return String(format: "%.1fG", gb)
    }
}

// MARK: - SwiftUI Views for Telemetry

struct SystemTelemetryExpandedView: View {
    let module: SystemTelemetryModule
    
    var body: some View {
        VStack(spacing: 12) {
            Text("SYSTEM TELEMETRY")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // 精致的双栏 IP 与 地理位置卡片
            HStack(spacing: 10) {
                // 卡片 1: IP 地址 (Local / Public)
                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.cyan)
                        .frame(width: 24, height: 24)
                        .background(Color.cyan.opacity(0.08), in: Circle())
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("IP ADDRESS")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.35))
                        
                        HStack(spacing: 4) {
                            Text(module.localIP)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                            Text("/")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white.opacity(0.25))
                            Text(module.publicIP)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.cyan.opacity(0.9))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                )
                
                // 卡片 2: 地理位置 Location
                HStack(spacing: 8) {
                    Image(systemName: "location.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 24, height: 24)
                        .background(Color.orange.opacity(0.08), in: Circle())
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GEOLOCATION")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.35))
                        
                        Text(module.location)
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                )
            }
            
            HStack(spacing: 8) {
                // CPU Panel
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 4)
                        Circle()
                            .trim(from: 0.0, to: CGFloat(min(module.cpuUsage / 100.0, 1.0)))
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [.green, .yellow, .red]),
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut, value: module.cpuUsage)
                        
                        VStack {
                            Text(String(format: "%.0f%%", module.cpuUsage))
                               .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text("CPU")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundStyle(.gray)
                        }
                    }
                    .frame(width: 50, height: 50)
                    
                    Text("\(module.cpuCores) Cores")
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                )
                
                // Memory Panel
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 4)
                        Circle()
                            .trim(from: 0.0, to: CGFloat(min(module.memoryUsage / 100.0, 1.0)))
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [.blue, Color(red: 90/255, green: 154/255, blue: 255/255), .purple]),
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut, value: module.memoryUsage)
                        
                        VStack {
                            Text(String(format: "%.0f%%", module.memoryUsage))
                               .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text("MEM")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundStyle(.gray)
                        }
                    }
                    .frame(width: 50, height: 50)
                    
                    Text("\(module.formattedMemoryUsed)/\(module.formattedMemoryTotal)")
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                )
                
                // Disk Panel
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 4)
                        Circle()
                            .trim(from: 0.0, to: CGFloat(min(module.diskUsage / 100.0, 1.0)))
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [.teal, Color(red: 90/255, green: 220/255, blue: 220/255), .cyan]),
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut, value: module.diskUsage)
                        
                        VStack {
                            Text(String(format: "%.0f%%", module.diskUsage))
                               .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text("DISK")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundStyle(.gray)
                        }
                    }
                    .frame(width: 50, height: 50)
                    
                    Text("\(module.formattedDiskUsed)/\(module.formattedDiskTotal)")
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                )
                
                // Network Panel
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("DOWNLOAD")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.gray)
                            Text(formatSpeedFull(module.downloadSpeed))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("UPLOAD")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.gray)
                            Text(formatSpeedFull(module.uploadSpeed))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    private func formatSpeedFull(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 {
            return String(format: "%.0f B/s", bytesPerSec)
        } else if bytesPerSec < 1024 * 1024 {
            return String(format: "%.1f KB/s", bytesPerSec / 1024.0)
        } else {
            return String(format: "%.1f MB/s", bytesPerSec / (1024.0 * 1024.0))
        }
    }
}

// MARK: - Helper Monitors

private class CpuMonitor {
    private var prevCpuInfo: processor_info_array_t?
    private var numPrevCpuInfo: mach_msg_type_number_t = 0
    private var numCPUs: uint32 = 0
    
    init() {
        var size = MemoryLayout<uint32>.size
        let result = sysctlbyname("hw.ncpu", &numCPUs, &size, nil, 0)
        if result != 0 {
            numCPUs = 1
        }
    }
    
    deinit {
        if let prev = prevCpuInfo {
            let size = vm_size_t(numPrevCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: Int(bitPattern: prev)), size)
        }
    }
    
    func getCpuUsage() -> Double {
        var numCpuInfo: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t?
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo)
        
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            return 0.0
        }
        
        defer {
            if let prev = prevCpuInfo {
                let size = vm_size_t(numPrevCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: Int(bitPattern: prev)), size)
            }
            prevCpuInfo = cpuInfo
            numPrevCpuInfo = numCpuInfo
        }
        
        guard let prev = prevCpuInfo else {
            return 0.0
        }
        
        var totalUsage: Double = 0.0
        
        for i in 0..<Int(numCPUs) {
            let base = i * Int(CPU_STATE_MAX)
            let user = Double(cpuInfo[base + Int(CPU_STATE_USER)] - prev[base + Int(CPU_STATE_USER)])
            let system = Double(cpuInfo[base + Int(CPU_STATE_SYSTEM)] - prev[base + Int(CPU_STATE_SYSTEM)])
            let idle = Double(cpuInfo[base + Int(CPU_STATE_IDLE)] - prev[base + Int(CPU_STATE_IDLE)])
            let nice = Double(cpuInfo[base + Int(CPU_STATE_NICE)] - prev[base + Int(CPU_STATE_NICE)])
            
            let total = user + system + idle + nice
            if total > 0 {
                totalUsage += (user + system + nice) / total
            }
        }
        
        return (totalUsage / Double(numCPUs)) * 100.0
    }
}

private class NetworkMonitor {
    private var prevBytesIn: UInt64 = 0
    private var prevBytesOut: UInt64 = 0
    private var lastTime = Date()
    
    func getNetworkSpeed() -> (downloadSpeed: Double, uploadSpeed: Double) {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return (0, 0)
        }
        
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            
            // IFF_UP = 0x1, IFF_LOOPBACK = 0x8
            if (flags & 0x1) != 0 && (flags & 0x8) == 0 {
                if addr.sa_family == UInt8(AF_LINK) {
                    let name = String(cString: ptr.pointee.ifa_name)
                    if name.hasPrefix("en") || name.hasPrefix("ap") || name.hasPrefix("p2p") {
                        if let data = ptr.pointee.ifa_data {
                            let networkData = data.assumingMemoryBound(to: if_data.self)
                            bytesIn += UInt64(networkData.pointee.ifi_ibytes)
                            bytesOut += UInt64(networkData.pointee.ifi_obytes)
                        }
                    }
                }
            }
        }
        
        let now = Date()
        let timeDiff = now.timeIntervalSince(lastTime)
        lastTime = now
        
        guard timeDiff > 0 else { return (0, 0) }
        
        // 首次运行防止由于初始差值过大网速暴涨
        let dlDiff = (prevBytesIn > 0 && bytesIn > prevBytesIn) ? bytesIn - prevBytesIn : 0
        let ulDiff = (prevBytesOut > 0 && bytesOut > prevBytesOut) ? bytesOut - prevBytesOut : 0
        
        prevBytesIn = bytesIn
        prevBytesOut = bytesOut
        
        return (Double(dlDiff) / timeDiff, Double(ulDiff) / timeDiff)
    }
}

struct MemoryDetails {
    let percentage: Double
    let used: UInt64
    let total: UInt64
}

private class MemoryMonitor {
    func getMemoryUsage() -> Double {
        return getMemoryDetails().percentage
    }
    
    func getMemoryDetails() -> MemoryDetails {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        
        let kerr = withUnsafeMutablePointer(to: &stats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        
        guard kerr == KERN_SUCCESS else {
            return MemoryDetails(percentage: 0.0, used: 0, total: 0)
        }
        
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        
        // macOS Activity Monitor standard calculation:
        // App Memory = internal_page_count - purgeable_count
        // Wired Memory = wire_count
        // Compressed Memory = compressor_page_count
        let appPages = stats.internal_page_count > stats.purgeable_count ? (stats.internal_page_count - stats.purgeable_count) : 0
        let appMemory = UInt64(appPages) * UInt64(pageSize)
        let wiredMemory = UInt64(stats.wire_count) * UInt64(pageSize)
        let compressedMemory = UInt64(stats.compressor_page_count) * UInt64(pageSize)
        
        let usedMemory = appMemory + wiredMemory + compressedMemory
        let safeUsedMemory = min(totalMemory, usedMemory)
        
        if totalMemory > 0 {
            let percentage = (Double(safeUsedMemory) / Double(totalMemory)) * 100.0
            return MemoryDetails(percentage: percentage, used: safeUsedMemory, total: totalMemory)
        }
        return MemoryDetails(percentage: 0.0, used: 0, total: 0)
    }
}

private class DiskMonitor {
    func getDiskUsage() -> (total: UInt64, free: UInt64, used: UInt64, percentage: Double) {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: "/")
            if let total = attrs[.systemSize] as? UInt64,
               let free = attrs[.systemFreeSize] as? UInt64 {
                let used = total - free
                let percentage = total > 0 ? (Double(used) / Double(total)) * 100.0 : 0.0
                return (total, free, used, percentage)
            }
        } catch {
            // fallback
        }
        return (0, 0, 0, 0.0)
    }
}
