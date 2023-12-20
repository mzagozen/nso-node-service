import ncs
from ncs.application import NanoService
from maagic_copy.maagic_copy import maagic_copy


class CreateDeviceAutomaton(NanoService):
    @NanoService.create
    def cb_nano_create(self, tctx, root, service, plan, component, state, proplist, component_proplist):
        # assume the component_proplist list contains a single entry - our DEVICE_NAME variable set in the plan
        if component_proplist[0][0] != 'DEVICE_NAME':
            raise ValueError(f'component_proplist does not contain the expected entry for DEVICE_NAME: {component_proplist}')
        device_name = component_proplist[0][1]
        automaton = root.devices.automaton.create(device_name)
        # instead of using maagic_copy we could set individual nodes in the automaton service, or use a template
        maagic_copy(service.device, automaton)
        return proplist


class Main(ncs.application.Application):
    def setup(self):
        self.register_nano_service('cpe-servicepoint', 'ce:cpe', 'ce:device-automaton-created', CreateDeviceAutomaton)