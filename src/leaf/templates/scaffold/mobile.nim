import leaf/mobile
import app/application

registerAndroidApplication(proc(resources: HostResources): Application =
  createApplication(resources = resources))
