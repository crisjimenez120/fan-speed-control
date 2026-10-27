import SMCKit

// Prints this Mac's fans and sensors.
let hw = try HardwareReader()
for f in hw.readFans() {
    print("\(f.name): \(Int(f.currentRPM)) RPM (target \(Int(f.targetRPM)), range \(Int(f.minRPM))–\(Int(f.maxRPM)))\(f.isManual ? " [manual]" : "")")
}
for s in hw.readSensors() {
    print(s.id.padding(toLength: 10, withPad: " ", startingAt: 0), s.name.padding(toLength: 28, withPad: " ", startingAt: 0), String(format: "%5.1f°C", s.celsius))
}
