import SMCKit

let hw = try HardwareReader()
for f in hw.readFans() { print(f) }
for s in hw.readSensors() where s.isSummary || s.group != .cpu { print(s.id, s.name, s.group, String(format: "%.1f", s.celsius)) }
