import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
func checked(_ status: OSStatus) { precondition(status == noErr, "CoreAudio error \(status)") }
var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
var size:UInt32=0
checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size))
var devices=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&devices))
var target:AudioDeviceID?
for id in devices {
 var prop=AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyName,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
 var name:CFString="" as CFString;var n=UInt32(MemoryLayout<CFString>.size)
 checked(AudioObjectGetPropertyData(id,&prop,0,nil,&n,&name))
 if (name as String)=="Microsoft Teams Audio" {target=id;print("Selected virtual output: \(name), id=\(id)")}
}
guard var device=target else {fatalError("Virtual device absent; no fallback allowed")}
if CommandLine.arguments.count==1 {exit(0)}
let engine=AVAudioEngine();guard let unit=engine.outputNode.audioUnit else {fatalError("No output unit")}
checked(AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,UInt32(MemoryLayout<AudioDeviceID>.size)))
func verifyRoute() {var actual:AudioDeviceID=0;var n=UInt32(MemoryLayout<AudioDeviceID>.size);checked(AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&actual,&n));if actual != device {engine.stop();fatalError("Output changed; playback stopped")}}
verifyRoute()
let file=try AVAudioFile(forReading:URL(fileURLWithPath:CommandLine.arguments[1]))
let player=AVAudioPlayerNode();engine.attach(player);engine.connect(player,to:engine.mainMixerNode,format:file.processingFormat)
player.scheduleFile(file,at:nil)
try engine.start();verifyRoute();player.play()
print("PLAYING virtual output only");fflush(stdout)
let until=Date().addingTimeInterval(Double(file.length)/file.processingFormat.sampleRate+1)
while Date()<until {verifyRoute();RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
player.stop();engine.stop();print("FINISHED")
