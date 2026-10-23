import leaf/mobile
import ./app

registerAndroidApplication(proc(resources: HostResources): Application =
  projectDemoApp(resources))
