#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <libkern/libkern.h>
#include <stdint.h>
#include "power_snapshot.h"

#define super IOService
class ApexTunePowerReader : public IOService {
    OSDeclareDefaultStructors(ApexTunePowerReader)
public:
    bool start(IOService *provider) override;
    IOReturn newUserClient(task_t task, void *securityID, UInt32 type,
                           IOUserClient **handler) override;
};
OSDefineMetaClassAndStructors(ApexTunePowerReader, IOService)
#define serviceSuper IOService

#undef super
#define super IOUserClient
class ApexTunePowerClient : public IOUserClient {
    OSDeclareDefaultStructors(ApexTunePowerClient)
public:
    bool initWithTask(task_t task, void *securityID, UInt32 type,
                      OSDictionary *properties) override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                            IOExternalMethodDispatch *dispatch = nullptr,
                            OSObject *target = nullptr, void *reference = nullptr) override;
    IOReturn clientClose(void) override;
private:
    friend class ApexTunePowerReader;
    ApexTunePowerReader *owner = nullptr;
};
OSDefineMetaClassAndStructors(ApexTunePowerClient, IOUserClient)

static bool supportedCPU() {
    uint32_t eax = 0, ebx = 0, ecx = 0, edx = 0;
    __asm__ volatile("cpuid" : "+a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx));
    if (ebx != 0x756e6547 || edx != 0x49656e69 || ecx != 0x6c65746e) return false;
    eax = 1;
    __asm__ volatile("cpuid" : "+a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx));
    const uint32_t baseFamily = (eax >> 8) & 0xf;
    const uint32_t extendedFamily = (eax >> 20) & 0xff;
    const uint32_t family = baseFamily == 0xf ? baseFamily + extendedFamily : baseFamily;
    const uint32_t baseModel = (eax >> 4) & 0xf;
    const uint32_t extendedModel = (eax >> 16) & 0xf;
    const uint32_t model = (baseFamily == 6 || baseFamily == 0xf)
                               ? (extendedModel << 4) | baseModel : baseModel;
    return family == 6 && model == 0x9e;
}

static uint64_t readMSR(uint32_t msr) {
    uint32_t low = 0, high = 0;
    __asm__ volatile("rdmsr" : "=a"(low), "=d"(high) : "c"(msr));
    return ((uint64_t)high << 32) | low;
}

bool ApexTunePowerReader::start(IOService *provider) {
    if (!serviceSuper::start(provider) || !supportedCPU()) return false;
    registerService();
    return true;
}

IOReturn ApexTunePowerReader::newUserClient(task_t task, void *securityID,
                                             UInt32 type, IOUserClient **handler) {
    (void)task;
    if (!handler || type != 0 || !securityID ||
        IOUserClient::clientHasPrivilege(securityID, kIOClientPrivilegeAdministrator) != kIOReturnSuccess)
        return kIOReturnNotPrivileged;
    ApexTunePowerClient *client = new ApexTunePowerClient;
    if (!client || !client->initWithTask(task, securityID, type, nullptr)) {
        if (client) client->release();
        return kIOReturnNoResources;
    }
    client->owner = this;
    if (!client->attach(this) || !client->start(this)) {
        client->detach(this);
        client->release();
        return kIOReturnError;
    }
    *handler = client;
    return kIOReturnSuccess;
}

bool ApexTunePowerClient::initWithTask(task_t task, void *securityID, UInt32 type,
                                       OSDictionary *properties) {
    if (IOUserClient::clientHasPrivilege(securityID, kIOClientPrivilegeAdministrator) != kIOReturnSuccess)
        return false;
    return super::initWithTask(task, securityID, type, properties);
}

IOReturn ApexTunePowerClient::externalMethod(uint32_t selector,
                                              IOExternalMethodArguments *args,
                                              IOExternalMethodDispatch *dispatch,
                                              OSObject *target, void *reference) {
    (void)dispatch; (void)target; (void)reference;
    if (IOUserClient::clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess)
        return kIOReturnNotPrivileged;
    if (selector != APT_SELECTOR_SNAPSHOT || !args || !owner ||
        args->scalarInputCount != 0 || args->structureInputSize != 0 ||
        args->scalarOutputCount != 0 || args->structureOutput == nullptr ||
        args->structureOutputSize != sizeof(apt_power_snapshot)) return kIOReturnBadArgument;
    if (!supportedCPU()) return kIOReturnUnsupported;

    apt_power_snapshot snapshot{};
    snapshot.magic = APT_POWER_MAGIC;
    snapshot.version = APT_POWER_VERSION;
    snapshot.size = sizeof(snapshot);
    snapshot.power_unit_msr = readMSR(APT_MSR_POWER_UNIT);
    snapshot.package_power_limit_msr = readMSR(APT_MSR_PACKAGE_POWER_LIMIT);
    bcopy(&snapshot, args->structureOutput, sizeof(snapshot));
    args->structureOutputSize = sizeof(snapshot);
    return kIOReturnSuccess;
}

IOReturn ApexTunePowerClient::clientClose(void) {
    terminate();
    return kIOReturnSuccess;
}
