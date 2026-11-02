#include <IOKit/IOLib.h>
#include <IOKit/IOCommandGate.h>
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOTimerEventSource.h>
#include <libkern/libkern.h>
#include <stdint.h>
#include "power_snapshot.h"

class ApexTunePowerClient;

#define super IOService
class ApexTunePowerReader : public IOService {
    OSDeclareDefaultStructors(ApexTunePowerReader)
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOReturn newUserClient(task_t task, void *securityID, UInt32 type,
                           IOUserClient **handler) override;
    IOWorkLoop *getWorkLoop() const override { return workLoop; }

    IOReturn snapshot(ApexTunePowerClient *client, apt_power_snapshot *out);
    IOReturn beginTrial(ApexTunePowerClient *client, const apt_trial_request *request,
                        apt_trial_result *result);
    IOReturn finishTrial(ApexTunePowerClient *client, apt_trial_result *result);
    IOReturn clientGone(ApexTunePowerClient *client);
private:
    static IOReturn stopAction(OSObject *, void *, void *, void *, void *);
    static IOReturn snapshotAction(OSObject *, void *, void *, void *, void *);
    static IOReturn beginAction(OSObject *, void *, void *, void *, void *);
    static IOReturn finishAction(OSObject *, void *, void *, void *, void *);
    static IOReturn goneAction(OSObject *, void *, void *, void *, void *);
    static void watchdogAction(OSObject *, IOTimerEventSource *);
    IOReturn restoreLease();

    IOWorkLoop *workLoop = nullptr;
    IOCommandGate *commandGate = nullptr;
    IOTimerEventSource *watchdog = nullptr;
    ApexTunePowerClient *leaseClient = nullptr;
    uint64_t originalLimit = 0;
    uint64_t appliedLimit = 0;
    bool stopping = false;
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
    IOReturn clientDied(void) override;
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

static uint64_t readPowerUnitMSR() {
    uint32_t low = 0, high = 0;
    __asm__ volatile("rdmsr" : "=a"(low), "=d"(high) : "c"(APT_MSR_POWER_UNIT));
    return ((uint64_t)high << 32) | low;
}

static uint64_t readPackageLimitMSR() {
    uint32_t low = 0, high = 0;
    __asm__ volatile("rdmsr" : "=a"(low), "=d"(high) : "c"(APT_MSR_PACKAGE_POWER_LIMIT));
    return ((uint64_t)high << 32) | low;
}

static void writePackageLimitMSR(uint64_t value) {
    const uint32_t low = (uint32_t)value;
    const uint32_t high = (uint32_t)(value >> 32);
    __asm__ volatile("wrmsr" : : "c"(APT_MSR_PACKAGE_POWER_LIMIT), "a"(low), "d"(high));
}

bool ApexTunePowerReader::start(IOService *provider) {
    if (!serviceSuper::start(provider) || !supportedCPU()) return false;
    workLoop = IOWorkLoop::workLoop();
    commandGate = IOCommandGate::commandGate(this);
    watchdog = IOTimerEventSource::timerEventSource(this, watchdogAction);
    if (!workLoop || !commandGate || !watchdog ||
        workLoop->addEventSource(commandGate) != kIOReturnSuccess ||
        workLoop->addEventSource(watchdog) != kIOReturnSuccess) return false;
    watchdog->disable();
    registerService();
    return true;
}

void ApexTunePowerReader::stop(IOService *provider) {
    IOReturn restoreStatus = kIOReturnSuccess;
    bool abandonLeaseAfterStop = false;
    if (commandGate)
        restoreStatus = commandGate->runAction(stopAction, &abandonLeaseAfterStop, nullptr, nullptr, nullptr);
    if (abandonLeaseAfterStop)
        IOLog("ApexTunePowerReader: stop could not confirm restoration (0x%x); saved original PL1/PL2 fields will be discarded\n",
              restoreStatus);
    if (watchdog) {
        watchdog->cancelTimeout();
        watchdog->disable();
        if (workLoop) workLoop->removeEventSource(watchdog);
        watchdog->release();
        watchdog = nullptr;
    }
    if (commandGate) {
        if (workLoop) workLoop->removeEventSource(commandGate);
        commandGate->release();
        commandGate = nullptr;
    }
    if (workLoop) {
        workLoop->release();
        workLoop = nullptr;
    }
    if (abandonLeaseAfterStop) {
        ApexTunePowerClient *formerClient = leaseClient;
        leaseClient = nullptr;
        originalLimit = 0;
        appliedLimit = 0;
        formerClient->owner = nullptr;
        formerClient->release();
    }
    serviceSuper::stop(provider);
    if (abandonLeaseAfterStop) release();
}

IOReturn ApexTunePowerReader::newUserClient(task_t task, void *securityID,
                                             UInt32 type, IOUserClient **handler) {
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

IOReturn ApexTunePowerReader::snapshot(ApexTunePowerClient *client, apt_power_snapshot *out) {
    return commandGate->runAction(snapshotAction, client, out);
}
IOReturn ApexTunePowerReader::beginTrial(ApexTunePowerClient *client,
                                          const apt_trial_request *request,
                                          apt_trial_result *result) {
    return commandGate->runAction(beginAction, client, (void *)request, result);
}
IOReturn ApexTunePowerReader::finishTrial(ApexTunePowerClient *client, apt_trial_result *result) {
    return commandGate->runAction(finishAction, client, result);
}
IOReturn ApexTunePowerReader::clientGone(ApexTunePowerClient *client) {
    return commandGate->runAction(goneAction, client);
}

IOReturn ApexTunePowerReader::stopAction(OSObject *owner, void *arg0, void *, void *, void *) {
    auto *self = OSDynamicCast(ApexTunePowerReader, owner);
    auto *leasePending = static_cast<bool *>(arg0);
    if (!self || !leasePending) return kIOReturnBadArgument;
    self->stopping = true;
    if (self->watchdog) {
        self->watchdog->cancelTimeout();
        self->watchdog->disable();
    }
    IOReturn status = self->restoreLease();
    *leasePending = self->leaseClient != nullptr;
    return status;
}

IOReturn ApexTunePowerReader::snapshotAction(OSObject *owner, void *arg0, void *arg1,
                                               void *, void *) {
    auto *self = OSDynamicCast(ApexTunePowerReader, owner);
    auto *client = OSDynamicCast(ApexTunePowerClient, (OSObject *)arg0);
    auto *out = (apt_power_snapshot *)arg1;
    if (!self || !client || !out) return kIOReturnBadArgument;
    if (self->stopping) return kIOReturnNotReady;
    apt_power_snapshot snapshot{};
    snapshot.magic = APT_POWER_MAGIC;
    snapshot.version = APT_POWER_VERSION;
    snapshot.size = sizeof(snapshot);
    snapshot.power_unit_msr = readPowerUnitMSR();
    snapshot.package_power_limit_msr = readPackageLimitMSR();
    bcopy(&snapshot, out, sizeof(snapshot));
    return kIOReturnSuccess;
}

IOReturn ApexTunePowerReader::beginAction(OSObject *owner, void *arg0, void *arg1,
                                            void *arg2, void *) {
    auto *self = OSDynamicCast(ApexTunePowerReader, owner);
    auto *client = OSDynamicCast(ApexTunePowerClient, (OSObject *)arg0);
    auto *request = (const apt_trial_request *)arg1;
    auto *result = (apt_trial_result *)arg2;
    if (!self || !client || !request || !result ||
        request->magic != APT_POWER_MAGIC || request->version != APT_POWER_VERSION ||
        request->size != sizeof(*request)) return kIOReturnBadArgument;
    if (self->stopping) return kIOReturnNotReady;
    if (self->leaseClient) return kIOReturnBusy;
    const uint64_t unit = readPowerUnitMSR();
    const uint64_t before = readPackageLimitMSR();
    uint64_t target = 0;
    if (!apt_build_trial_limit(unit, before, request->pl1_watts, request->pl2_watts,
                               request->duration_seconds, &target)) return kIOReturnNotPermitted;
    self->originalLimit = before;
    self->appliedLimit = target;
    self->leaseClient = client;
    client->retain();
    self->retain();
    self->watchdog->enable();
    if (self->watchdog->setTimeoutMS(APT_WATCHDOG_MAX_SECONDS * 1000) != kIOReturnSuccess) {
        self->watchdog->disable();
        self->leaseClient = nullptr;
        self->originalLimit = 0;
        self->appliedLimit = 0;
        client->release();
        self->release();
        return kIOReturnError;
    }
    writePackageLimitMSR(target);
    const uint64_t applied = readPackageLimitMSR();
    self->appliedLimit = applied;
    if (applied != target) {
        const IOReturn restoreStatus = self->restoreLease();
        const uint64_t restored = readPackageLimitMSR();
        bzero(result, sizeof(*result));
        result->magic = APT_POWER_MAGIC;
        result->version = APT_POWER_VERSION;
        result->size = sizeof(*result);
        result->before_raw = before;
        result->applied_raw = applied;
        result->restored_raw = restored;
        return restoreStatus == kIOReturnSuccess ? kIOReturnError : restoreStatus;
    }
    bzero(result, sizeof(*result));
    result->magic = APT_POWER_MAGIC;
    result->version = APT_POWER_VERSION;
    result->size = sizeof(*result);
    result->duration_seconds = request->duration_seconds;
    result->before_raw = before;
    result->applied_raw = applied;
    return kIOReturnSuccess;
}

IOReturn ApexTunePowerReader::restoreLease() {
    if (!leaseClient) return kIOReturnSuccess;
    const uint64_t current = readPackageLimitMSR();
    uint64_t expected = 0;
    if (!apt_build_restore_limit(current, originalLimit, &expected)) {
        watchdog->cancelTimeout();
        watchdog->disable();
        IOLog("ApexTunePowerReader: restore blocked because package power limit lock is set\n");
        return kIOReturnNotPermitted;
    }
    writePackageLimitMSR(expected);
    const uint64_t restored = readPackageLimitMSR();
    if (restored != expected) {
        watchdog->cancelTimeout();
        watchdog->disable();
        IOLog("ApexTunePowerReader: restore readback mismatch; automatic retries stopped\n");
        return kIOReturnError;
    }
    ApexTunePowerClient *formerClient = leaseClient;
    watchdog->cancelTimeout();
    watchdog->disable();
    leaseClient = nullptr;
    originalLimit = 0;
    appliedLimit = 0;
    formerClient->release();
    release();
    return kIOReturnSuccess;
}

IOReturn ApexTunePowerReader::finishAction(OSObject *owner, void *arg0, void *arg1,
                                             void *, void *) {
    auto *self = OSDynamicCast(ApexTunePowerReader, owner);
    auto *client = OSDynamicCast(ApexTunePowerClient, (OSObject *)arg0);
    auto *result = (apt_trial_result *)arg1;
    if (!self) return kIOReturnBadArgument;
    if (!self->leaseClient) return kIOReturnSuccess;
    if (self->stopping) return kIOReturnNotReady;
    if (client && self->leaseClient != client) return kIOReturnNotPermitted;
    const uint64_t before = self->originalLimit;
    const uint64_t applied = self->appliedLimit;
    IOReturn status = self->restoreLease();
    const uint64_t restored = readPackageLimitMSR();
    if (result) {
        bzero(result, sizeof(*result));
        result->magic = APT_POWER_MAGIC;
        result->version = APT_POWER_VERSION;
        result->size = sizeof(*result);
        result->before_raw = before;
        result->applied_raw = applied;
        result->restored_raw = restored;
    }
    return status;
}

IOReturn ApexTunePowerReader::goneAction(OSObject *owner, void *arg0, void *, void *, void *) {
    auto *self = OSDynamicCast(ApexTunePowerReader, owner);
    auto *client = OSDynamicCast(ApexTunePowerClient, (OSObject *)arg0);
    if (!self || !client) return kIOReturnBadArgument;
    if (self->stopping) return kIOReturnNotReady;
    if (self->leaseClient && self->leaseClient != client) return kIOReturnSuccess;
    return self->leaseClient ? self->restoreLease() : kIOReturnSuccess;
}

void ApexTunePowerReader::watchdogAction(OSObject *owner, IOTimerEventSource *) {
    auto *self = OSDynamicCast(ApexTunePowerReader, owner);
    if (self && self->leaseClient) self->restoreLease();
}

IOReturn ApexTunePowerClient::externalMethod(uint32_t selector,
                                              IOExternalMethodArguments *args,
                                              IOExternalMethodDispatch *dispatch,
                                              OSObject *target, void *reference) {
    (void)dispatch; (void)target; (void)reference;
    if (IOUserClient::clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess)
        return kIOReturnNotPrivileged;
    if (!args || !owner || args->scalarInputCount != 0 || args->scalarOutputCount != 0)
        return kIOReturnBadArgument;
    if (selector == APT_SELECTOR_SNAPSHOT) {
        if (args->structureInputSize != 0 || !args->structureOutput ||
            args->structureOutputSize != sizeof(apt_power_snapshot)) return kIOReturnBadArgument;
        apt_power_snapshot snapshot{};
        IOReturn status = owner->snapshot(this, &snapshot);
        if (status == kIOReturnSuccess) bcopy(&snapshot, args->structureOutput, sizeof(snapshot));
        return status;
    }
    if (selector == APT_SELECTOR_BEGIN_TRIAL) {
        if (!args->structureInput || args->structureInputSize != sizeof(apt_trial_request) ||
            !args->structureOutput || args->structureOutputSize != sizeof(apt_trial_result))
            return kIOReturnBadArgument;
        apt_trial_request request{};
        apt_trial_result result{};
        bcopy(args->structureInput, &request, sizeof(request));
        IOReturn status = owner->beginTrial(this, &request, &result);
        bcopy(&result, args->structureOutput, sizeof(result));
        return status;
    }
    if (selector == APT_SELECTOR_FINISH_TRIAL) {
        if (args->structureInputSize != 0 || !args->structureOutput ||
            args->structureOutputSize != sizeof(apt_trial_result)) return kIOReturnBadArgument;
        apt_trial_result result{};
        IOReturn status = owner->finishTrial(this, &result);
        bcopy(&result, args->structureOutput, sizeof(result));
        return status;
    }
    return kIOReturnBadArgument;
}

IOReturn ApexTunePowerClient::clientClose(void) {
    IOReturn status = owner ? owner->clientGone(this) : kIOReturnSuccess;
    terminate();
    return status;
}

IOReturn ApexTunePowerClient::clientDied(void) {
    if (owner) owner->clientGone(this);
    return super::clientDied();
}
