# Creating truly declarative services with NSO

## TODO before publishing

- [ ] Install prerequisites in devpod container image
  - [ ] xmlstarlet (device-automaton pre-processing)
  - [ ] openssl-devel (build scrypt wheel for Python 3.11)

### Ideas for extending the lab

Depending on the "time" available, we could extend this lab further, or create
new labs that build on top of this one. Some ideas:
- [ ] Extend the node service to configure in-band management and show nano plan
  backtracking
- [ ] Show how to add CFS on top of the node service

## Prerequisites

This learning lab assumes you are familiar with the following NSO concepts:
- Onboarding devices in NSO (NEDs, netsim)
- NSO service package development (YANG, Python, XML templates)
- nano services

##  What is a "node" service?
Many users of NSO set off on their automation journey by wanting to create
services that configure an aspect of their network. For example a service that
will deploy a L3VPN for their customer. They create a service model, the mapping
logic, and things usually work in a test environment. But further down the line,
they figure that their services do not work when configuring a device completely
from scratch (because they didn't define ordering dependencies but instead let a
human operator figure it out) or that things break down after a software upgrade
because the configuration (model) has changed.

This package includes an example of a service that is solely responsible for the
configuration of a single device. The service model is composed of different
parts, each part corresponding to one of the configuration aspects of the
device. These parts map to different lower layer services that are responsible
for applying the configuration. In fact the containers within the model are
usages of groupings that are defined in other services, including device
automaton. The container 'device' uses the 'device-automaton-grouping', and so
on.

The node service is also aware of the dependencies between different parts of
the device configuration and is able to configure the device in multiple stages.
The service is implemented as a nano-service with a plan that creates the
automaton service instance in the first state. The next state uses another
service to apply some configuration to the device. It includes a pre-condition
that monitors the "readiness" of the device by observing the `device-ready``
leaf in the automaton service. The leaf will only be set to 'true' after the
automaton has completed its initial device onboarding process. In this example
service all device configuration could be applied in a single transaction,
meaning we only needed one nano-service state. A scenario for splitting the
device configuration across multiple NSO transactions is if you start with
onboarding the device over an OOB link (which could be very slow) and want to
switch to a different link before applying the bulk of configuration. You can do
so by adding another nano-service state after the device is ready, but before
creating other services, for configuring just connectivity.

## What is the "device automaton" service?

In a nutshell, the device automaton service enables declarative device
management in NSO. It provides closed loop automation for a number of common
scenarios that are otherwise challenging to handle in a plain NSO environment.
Its defining feature is a declarative interface - a service model that collects
all the inputs needed to onboard a device in NSO. This kicks of a series of
background tasks that perform the iterative steps of actually adding a device to
NSO. Through the use of operational data leaves the device automaton also
notifies other services further up the stack of any changes in the device
configuration or state. This enables the services to react to changes
autonomously. For example, a service could re-deploy the device configuration
when the device configuration drifts from the service expectations.

For more details on the device automaton service we invite you to read the
documentation and use cases available at
https://gitlab.com/nso-developer/device-automaton.

## Example CPE node service 

Let us examine a simple node nano service that is included in the device
automaton documentation. The service is primarily used to show how to use the
automaton to create a truly declarative service in NSO that not only provides
device with configuration but also onboards the device in NSO. The actual
configuration applied by this service is very modest - just configure the
hostname on the supported platform. On a high-level the cpe node service creates
two other services: device-automaton and base-config:

```
           ┌──────────────────────┐
           │ /nodes/cpe           │
           └──┬─────────────────┬─┘
              │                 │
┌─────────────▼───────┐ ┌───────▼────────────┐
│ /devices/automaton  │ │ /rfs/base-config   │
└─────────────────────┘ └────────────────────┘
```

## Setting up the environment

### Starting a local NSO instance

The Cloud IDE environment is includes a local installation of NSO 6.2. The
install directory is available in the `$NCS_DIR` environment variable. Your
shell is already set up to include binaries in the `$NCS_DIR/bin` directory.
Start by creating a new NSO running directory in `~/nso-run`:

```shell
ncs-setup --dest ~/nso-run
```

Output:

```shell
developer:~ > ncs-setup --dest ~/nso-run
```

Now before you start the new NSO instance, install the `device-automaton`
package and its dependencies. The package is available at
https://gitlab.com/nso-developer/device-automaton and its dependencies are:
- [maagic-copy](https://gitlab.com/nso-developer/maagic-copy): a Python package
  used to copy data between different parts of the schema tree
- [py-alarm-sink](https://gitlab.com/nso-developer/py-alarm-sink): a Python
  package that provides an API or creating alarms in NSO
- [bgworker](https://gitlab.com/nso-developer/bgworker): a Python package that
  manages the lifecycle of background worker processes in NSO
- At least one NED package, for example `cisco-ios-cli-3.8` included in the NSO
  installation

In addition to these NSO packages, each package also depends on a number of
Python packages that are not included in the NSO installation, but are available
for download from PyPI. These are listed in the `requirements.txt` and
`requirements-dev.txt` files in each NSO package.

First you will add the `cisco-ios-cli-3.8` NED package to by copying it from the
local installation directory:

```shell
cp -pr $NCS_DIR/packages/neds/cisco-ios-cli-3.8 nso-run/packages/
```

To streamline the process we have created a helper script that will download all
NSO packages by cloning the Git repositories and install the Python
dependencies. Run the following command to install the packages in your local
NSO running directory:

```shell
make install
```

Output:

```shell
developer:~ > make install
[... output omitted for brevity ...]
```

Finally you can start the new local NSO instance and verify it is running:

```shell
ncs --dir ~/nso-run
ncs_cli -u admin
```

Output:

```shell
developer:~ > ncs --dir ~/nso-run
developer:~ > ncs_cli -u admin
User admin last logged in 2023-12-20T13:22:03.737819+00:00, to devpod-6787747156063843889-7779fccdbd-6nsnp, from 127.0.0.1 using cli-console
admin connected from 127.0.0.1 using console on devpod-6787747156063843889-7779fccdbd-6nsnp
admin@ncs>
```

## Building the `base-config` resource-facing service (RFS)

The first building block you need to create is the `base-config` resource-facing
service (RFS). In the example we only use the `base-config` service to configure
hostname, but you can imagine a more complex realistic service or even a stack
of services that includes arbitrary configuration.

Note: if at any point you get stuck, you can find the full `cpe-example` service
package in the `solution/cpe-example` directory.

Start by creating a new service package that will contain all the service models
and mapping logic:

```shell
ncs-make-package --service-skeleton python --dest nso-run/packages/cpe-example cpe-example
```

First you will change the default YANG module prefix from `cpe-example` to `ce`,
to keep the expressions used throughtout the rest of the package shorter. Open
the `nso-run/packages/cpe-example/src/yang/cpe-example.yang` file and change the
`prefix cpe-example;` statement to `prefix ce;`:

```diff
module cpe-example {

  namespace "http://example.com/cpe-example";
-  prefix cpe-example;
+  prefix ce;
```

You will define the `base-config` service by editing the `cpe-example.yang`
file. Here is a tree representation of the final service model for the
`base-config` service, obtained with `pyang -f tree cpe-example.yang`:

```
module: cpe-example
  +--rw rfs
     +--rw base-config* [device]
        +--rw device      -> /ncs:devices/device/name
        +--rw hostname    string
```

To achieve this, you need to define a new grouping named `base-config-grouping`
that will be used by both the `/rfs/base-config` resource facing service and the
`/nodes/cpe` node service. Open the newly created
`nso-run/packages/cpe-example/src/yang/cpe-example.yang` file from the new NSO
package in the editor and define a `base-config-grouping` grouping containing a
`hostname` leaf. Replace the existing `list cpe-example` root node definition
with the following:

```yang
  grouping base-config-grouping {
    leaf hostname {
      type string;
      mandatory true;
    }
  }
```

Then, create the `base-config` service model by defining the top-level `rfs`
container and the `base-config` service list within. Use the previously defined
`base-config-grouping` grouping to pull in the `hostname` leaf:

```yang
  container rfs {
    list base-config {
      ncs:servicepoint base-config-servicepoint;
      uses ncs:service-data;

      key device;
      leaf device {
        type leafref {
          path "/ncs:devices/ncs:device/ncs:name";
        }
      }

      uses base-config-grouping;
    }
  }
```

To wrap up the `base-config` service definition you need to register a service
create callback for the `base-config-servicepoint` servicepoint. For this simple
example you will just use a service template. Create a new file in the
`nso-run/packages/cpe-example/templates` directory (if the `templates` directory
does not exist, create it) named `base-config.xml` and add the following
content:

```xml
<config-template xmlns="http://tail-f.com/ns/config/1.0" servicepoint="base-config-servicepoint">
  <devices xmlns="http://tail-f.com/ns/ncs" tags="nocreate">
    <device>
      <name>{/device}</name>
      <config tags="merge">
        <hostname xmlns="urn:ios">{/hostname}</hostname>
      </config>
    </device>
  </devices>
</config-template>
```

### Building the first iteration of the `cpe` node service

In the first iteration of the `cpe` node service you will create a nano-service
that will expose the input parameters of the `base-config` service and operate
on an existing device.

Open the `cpe-example.yang` file and add a top-level `container nodes` data node
and within in the `list cpe` node that will represent the `cpe` node service:

```yang
  container nodes {
    list cpe {
      ncs:servicepoint cpe-servicepoint;
      uses ncs:service-data;
      uses ncs:nano-plan-data;

      key name;

      leaf name {
        type string;
      }

      container base-config {
        uses base-config-grouping;
      }
    }
  }
```

The nano service plan in the first stage will be very simple - just create the
`base-config` service instance. Add the following nano service plan definition
to the `cpe-example.yang` file:

```yang
  identity cpe {
    base ncs:plan-component-type;
  }

  identity base-config-created {
    base ncs:plan-state;
  }

  ncs:plan-outline cpe-plan {
    ncs:self-as-service-status;

    ncs:component-type "ncs:self" {
      ncs:state "ncs:init";
      ncs:state "ncs:ready";
    }
    ncs:component-type "ce:cpe" {
      ncs:state "ncs:init";
      ncs:state "ce:base-config-created" {
        ncs:create {
          ncs:nano-callback;
        }
      }
      ncs:state "ncs:ready";
    }
  }

  ncs:service-behavior-tree cpe-servicepoint {
    ncs:plan-outline-ref cpe-plan;
    ncs:selector {
      ncs:variable "DEVICE_NAME" {
        ncs:value-expr "$SERVICE/name";
      }
      ncs:create-component "'self'" {
        ncs:component-type-ref "ncs:self";
      }
      ncs:create-component "$DEVICE_NAME" {
        ncs:component-type-ref "ce:cpe";
      }
    }
  }
```

In a nano service plan, each component state may use a callback to implement the
service mapping logic for that state. In this example you will implement the
`base-config-created` state callback in an XML template. Create a new file in
the `nso-run/packages/cpe-example/templates` directory named
`cpe-base-config-created.xml` and add the following content:

```xml
<config-template xmlns="http://tail-f.com/ns/config/1.0"
                 xmlns:link="http://example.com/cpe-example"
                 servicepoint="cpe-servicepoint"
                 componenttype="ce:cpe"
                 state="ce:base-config-created">
  <!-- This state primarily creates the device configuration - indirectly using
the /rfs/base-config service. When this template is evaluated the context node
is set to the instance of the cpe service: /nodes/cpe{foo}. The $DEVICE_NAME
variable was set when the nano-service plan was synthesized by NSO. -->
  <rfs xmlns="http://example.com/cpe-example">
    <base-config>
      <device>{$DEVICE_NAME}</device>
      <hostname>{/base-config/hostname}</hostname>
    </base-config>
  </rfs>
</config-template>
```

### Adding the device automaton service 

In the second iteration of the `cpe` node service you will extend the service
model and the nano service plan to create the automaton service instance for
onboarding a new device.

Switch your editor to edit the
`nso-run/packages/cpe-example/src/yang/cpe-example.yang` file and import a new
module that defines the automaton service model grouping:

```diff
module cpe-example {
  yang-version "1.1";

  namespace "http://example.com/cpe-example";
  prefix ce;

  import tailf-ncs {
    prefix ncs;
  }

+  import device-automaton-groupings {
+    prefix devaut-groupings;
+  }
```

Now you can use the `devaut-groupings:device-automaton-grouping` grouping in the
node service model to expose the input parameters of the automaton service:

```diff
  container nodes {
    list cpe {
  [...]

      leaf name {
        type string;
      }

+      container device {
+        uses devaut-groupings:device-automaton-grouping;
+      }

      container base-config {
        uses base-config-grouping;
      }
    }
  }
```

The automaton service instance will be created in the first stage of the nano
service. Extend the nano service plan definition to add this in
`cpe-example.yang`:

```diff
+  identity device-automaton-created {
+    base ncs:plan-state;
+  }

  ncs:plan-outline cpe-plan {
    ncs:self-as-service-status;

    ncs:component-type "ncs:self" {
      ncs:state "ncs:init";
      ncs:state "ncs:ready";
    }
    ncs:component-type "ce:cpe" {
      ncs:state "ncs:init";
+      ncs:state "ce:device-automaton-created" {
+        ncs:create {
+          ncs:nano-callback;
+        }
+      }
      ncs:state "ce:base-config-created" {
        ncs:create {
          ncs:nano-callback;
        }
      }
      ncs:state "ncs:ready";
    }
  }
```

The existing `base-config-created` state callback must now be held back until
the automaton service is ready, meaning the device was added to NSO and the
initial onboarding was completed. Add a pre-condition to the existing state that
will monitor the `device-ready` leaf in the automaton service:

```diff
  ncs:plan-outline cpe-plan {
    ncs:self-as-service-status;

    ncs:component-type "ncs:self" {
      ncs:state "ncs:init";
      ncs:state "ncs:ready";
    }
    ncs:component-type "ce:cpe" {
      ncs:state "ncs:init";
      ncs:state "ce:device-automaton-created" {
        ncs:create {
          ncs:nano-callback;
        }
      }
      ncs:state "ce:base-config-created" {
        ncs:create {
          ncs:nano-callback;
+          ncs:pre-condition {
+            ncs:monitor "/ncs:devices/automaton[device=$DEVICE_NAME]/device-ready" {
+              ncs:trigger-expr ". = 'true'";
+            }
+          }
        }
      }
      ncs:state "ncs:ready";
    }
  }
```

Finally you can implement the `device-automaton-created` state *create*
callback. The callback will create the automaton service instance by copying the
relevant service input parameters from the node service to the automaton
service. There are many ways to achieve this, but in this example you will use
Python. To avoid having to copy all the nodes in the automaton service model
individually, you will use the `maagic_copy` function from the *maagic-copy*
package. The `maagic_copy` function is similar to the built-in
`ncs.maapi.Transaction.copy_tree` function - it recursively copies data from one
part of the schema tree to another. The main difference lies in the flexibility
of the functions. The `maagic_copy` function will skip source nodes not found in
the target structure, while `copy_tree` requires all nodes present in the target
structure. The package is available at
https://gitlab.com/nso-developer/maagic-copy and is already included in the
environment. To make it available to the `cpe-example` NSO package, add the
following to `nso-run/packages/cpe-example/package-meta-data.xml`:

```diff
<ncs-package xmlns="http://tail-f.com/ns/ncs-packages">
  <name>cpe-example</name>
  <package-version>1.0</package-version>
  <ncs-min-version>6.2</ncs-min-version>

+  <required-package>
+    <name>maagic-copy</name>
+  </required-package>
```

Now edit the `nso-run/packages/cpe-example/src/cpe_example/main.py` file to
implement the *create* callback for the `device-automaton-created` state.
Replace the contents of the file with the following:

```python
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
```

### Extending the `cpe` node service to react to device configuration changes

In the third iteration of the `cpe` node service you will extend the service to
react to changes in the device configuration. With the help of the automaton
service, the node service will be able to detect when the device configuration
is out of sync with the service expectations and trigger a re-deploy to remedy
the situation.

The automaton service model includes an operational `re-deploy-trigger` boolean
leaf. This leaf is automatically flipped from *false* to *true* and then back to
*false* when then automaton feels the device configuration may be inconsistent
with the service expectations. There are multiple reasons for this: detected
out-of-sync state, commit queue item has failed, ned-id was changed. Whatever
the reason, any service can create a kicker to easily subscribe to changes and
react accordingly (re-deploy).

There are many ways to create a kicker from service mapping logic. In this lab
you will use the existing
`nso-run/packages/cpe-example/templates/cpe-base-config-created.xml` template.
Remember, it implements the `base-config-created` state *create* callback. Add
the following to the template:

```diff
<config-template xmlns="http://tail-f.com/ns/config/1.0"
                 xmlns:link="http://example.com/cpe-example"
                 servicepoint="cpe-servicepoint"
                 componenttype="ncs:self"
                 state="ce:base-config-created">
  <rfs xmlns="http://example.com/cpe-example">
    <base-config>
      <device>{$DEVICE_NAME}</device>
      <hostname>{/base-config/hostname}</hostname>
    </base-config>
  </rfs>
+  <kickers xmlns="http://tail-f.com/ns/kicker">
+    <data-kicker>
+      <id>cpe-node-{/name}-re-deploy-trigger</id>
+      <monitor>/ncs:devices/devaut:automaton[devaut:device='{$DEVICE_NAME}']/re-deploy-trigger</monitor>
+      <trigger-expr>. = 'true' and ../device-ready = 'true'</trigger-expr>
+      <kick-node>/ce:nodes/ce:cpe[ce:name='{/name}']</kick-node>
+      <!-- Note the intentional use of the 're-deploy' action here. It is common
+to use 'reactive-re-deploy' in combination with (nano-)services due to its
+asynchronous nature and the fact that requests are queued up. Unfortunately
+'reactive-re-deploy' implies a shallow re-deploy. When services are stacked (one
+top-level service creates other services which in turn create device
+configuration) a shallow re-deploy only triggers the mapping logic of the top
+service. If no inputs to the lower layer services are changed the mapping logic
+for those does not run. This is normally a good optimization because it reduces
+the time needed to run create callbacks. However it does not work as expected if
+the device configuration changes. Because device configuration is *not* part of
+the service inputs, a shallow re-deploy detects no changes. There is currently
+no 'reactive-re-deploy-deep' action in NSO. -->
+      <action-name>re-deploy</action-name>
+    </data-kicker>
+  </kickers>
</config-template>
```

To use the new module you also need to execute the pre-processing step at
package build time. Open the `nso-run/packages/cpe-example/src/Makefile` file and add the
following lines:

```diff
SRC = $(wildcard yang/*.yang)
DIRS = ../load-dir
FXS = $(SRC:yang/%.yang=../load-dir/%.fxs)

+# Include the YANG pre-processing recipe for removing backwards-incompatible
+# parts of the model
+DEVICE_AUTOMATON_PACKAGE = ../../device-automaton/src/
+include $(DEVICE_AUTOMATON_PACKAGE)yang-preprocessor.mk

+../load-dir/cpe-example.fxs: yang/device-automaton-groupings.yang
+YANGPATH = yang
```

### Compiling and loading the `cpe-example` package

Now you can compile and load the `cpe-example` in NSO. Compiling the package is
as simple as running `make` in the `nso-run/packages/cpe-example/src` directory.

```shell
make -C nso-run/packages/cpe-example/src
```

Output:

```shell
developer:~ > make -C nso-run/packages/cpe-example/src
make: Entering directory '/home/developer/nso-run/packages/cpe-example/src'
mkdir -p ../load-dir
/home/mzagozen/nso-6.1/bin/ncsc  `ls cpe-example-ann.yang  > /dev/null 2>&1 && echo "-a cpe-example-ann.yang"` \
        --fail-on-warnings \
        --yangpath ../../device-automaton/src/yang \
        -c -o ../load-dir/cpe-example.fxs yang/cpe-example.yang
/home/mzagozen/nso-6.1/bin/ncsc  `ls device-automaton-groupings-ann.yang  > /dev/null 2>&1 && echo "-a device-automaton-groupings-ann.yang"` \
        --fail-on-warnings \
        --yangpath ../../device-automaton/src/yang \
        -c -o ../load-dir/device-automaton-groupings.fxs yang/device-automaton-groupings.yang
make: Leaving directory '/home/developer/nso-run/packages/cpe-example/src'
```

To load the package in NSO, run the following command:

```shell
ncs_cli -u admin
request packages reload
```

Output:

```shell
developer:~ > ncs_cli -u admin
User admin last logged in 2023-12-20T13:22:03.737819+00:00, to devpod-6787747156063843889-7779fccdbd-6nsnp, from 127.0.0.1 using cli-console
admin connected from 127.0.0.1 using console on devpod-6787747156063843889-7779fccdbd-6nsnp
admin@ncs> request packages reload 

>>> System upgrade is starting.
>>> Sessions in configure mode must exit to operational mode.
>>> No configuration changes can be performed until upgrade has completed.
>>> System upgrade has completed successfully.
reload-result {
    package bgworker
    result true
}
reload-result {
    package cpe-example
    result true
}
reload-result {
    package device-automaton
    result true
}
reload-result {
    package maagic-copy
    result true
}
reload-result {
    package py-alarm-sink
    result true
}
[ok][2023-12-20 14:22:26]
admin@ncs> 
System message at 2023-12-20 14:22:26...
    Subsystem stopped: ncs-dp-1-cisco-ios-cli-3.8:IOSDp2
admin@ncs> 
System message at 2023-12-20 14:22:26...
    Subsystem stopped: ncs-dp-2-cisco-ios-cli-3.8:IOSDp
admin@ncs> 
System message at 2023-12-20 14:22:26...
    Subsystem started: ncs-dp-3-cisco-ios-cli-3.8:IOSDp2
admin@ncs> 
System message at 2023-12-20 14:22:26...
    Subsystem started: ncs-dp-4-cisco-ios-cli-3.8:IOSDp
```

## Creating a netsim device

The Cloud IDE does not include physical devices to test your services on. But as
with any NSO installation you can always create a *netsim* device. Netsim
devices emulate the management plane of a device and are a lightweight method
for testing NSO services. Enter the three commands to create a netsim device
named `cpe0`, start it and list the CLI (SSH) port that will be later used to
connect to the device:

```shell
ncs-netsim create-network $NCS_DIR/packages/neds/cisco-ios-cli-3.8 1 cpe
ncs-netsim start
ncs-netsim get-port cpe0 cli
```

Output:

```shell
developer:~ > ncs-netsim create-network $NCS_DIR/packages/neds/cisco-ios-cli-3.8 1 cpe
DEVICE cpe0 CREATED
developer:~ > ncs-netsim start
DEVICE cpe0 OK STARTED
developer:~ > ncs-netsim get-port cpe0 cli
10022
```

## Testing the `cpe` node service

Now you can test the `cpe` node service to onboard the netsim device and apply
the `base-config` service. The full service configuration is listed below:

```
nodes {
  cpe test {
    device {
        ned-id cisco-ios-cli-3.8;
        management-endpoint localhost {
          port 10022;
        }
        management-credentials {
            username admin;
            password admin;
        }
    }
    base-config {
      hostname test;
    }
  }
}
```

You can copy and paste the configuration directly into NSO CLI (configure mode)
by using `load merge terminal` and pressing `Ctrl+D` at the end. Before
committing execute a `commit dry-run` to see what changes will be applied when
you create the node service instance:

```shell
ncs_cli -u admin
configure
load merge terminal
<PASTE>
<Ctrl+D>
commit
```

Output: 
```
developer:~ > ncs_cli -u admin
User admin last logged in 2023-12-20T13:43:40.436033+00:00, to devpod-6787747156063843889-7779fccdbd-6nsnp, from 127.0.0.1 using cli-console
admin connected from 127.0.0.1 using console on devpod-6787747156063843889-7779fccdbd-6nsnp
admin@ncs> configure 
Entering configuration mode private
[ok][2023-12-20 22:00:30]

[edit]
admin@ncs% load merge terminal
nodes {
  cpe test {
    device {
        ned-id cisco-ios-cli-3.8;
        management-endpoint localhost {
          port 10022;
        }
        management-credentials {
            username admin;
            password admin;
        }
    }
    base-config {
      hostname test;
    }
  }
}

[ok][2023-12-20 22:01:00]

[edit]
admin@ncs% commit dry-run 
cli {
    local-node {
        data  devices {
                  authgroups {
             +        group test {
             +            default-map {
             +                remote-name admin;
             +                remote-password $9$WHy0iB7vmilrO7c84VMS3a5hu/YygiTFfCa5cEC7zR0=;
             +            }
             +        }
                  }
             +    device test {
             +        address localhost;
             +        port 10022;
             +        authgroup test;
             +        device-type {
             +            cli {
             +                ned-id cisco-ios-cli-3.8;
             +            }
             +        }
             +        commit-queue {
             +            enabled-by-default false;
             +        }
             +        state {
             +            admin-state unlocked;
             +        }
             +    }
             +    automaton test {
             +        ned-id cisco-ios-cli-3.8;
             +        management-endpoint localhost {
             +            port 10022;
             +        }
             +        management-credentials {
             +            username admin;
             +            password $9$WHy0iB7vmilrO7c84VMS3a5hu/YygiTFfCa5cEC7zR0=;
             +        }
             +    }
              }
              nodes {
             +    cpe test {
             +        device {
             +            ned-id cisco-ios-cli-3.8;
             +            management-endpoint localhost {
             +                port 10022;
             +            }
             +            management-credentials {
             +                username admin;
             +                password $9$WHy0iB7vmilrO7c84VMS3a5hu/YygiTFfCa5cEC7zR0=;
             +            }
             +        }
             +        base-config {
             +            hostname test;
             +        }
             +    }
              }
    }
}
[ok][2023-12-20 22:02:28]

[edit]
admin@ncs% commit 
Commit complete.
```

Note how the output of `commit dry-run` contains the `/nodes/cpe{test}` node
service instance data in the last section. In the first section you can see the
`/devices/device{test}` list entry created by the device automaton, as well as
the `/devices/automaton{test}` automaton service instance itself.

You can now observe the progress of the nano service plan by running the `show
nodes cpe test plan` command in NSO CLI:

```shell
show nodes cpe test plan
```

Output:
```shell
admin@ncs> show nodes cpe test plan
                                                                                      POST    
            BACK                                                                      ACTION  
TYPE  NAME  TRACK  GOAL  STATE                     STATUS   WHEN                 ref  STATUS  
----------------------------------------------------------------------------------------------
self  self  false  -     init                      reached  2023-12-20T21:05:51  -    -       
                         ready                     reached  2023-12-20T21:05:56  -    -       
cpe   test  false  -     init                      reached  2023-12-20T21:05:51  -    -       
                         device-automaton-created  reached  2023-12-20T21:05:51  -    -       
                         base-config-created       reached  2023-12-20T21:05:56  -    -       
                         ready                     reached  2023-12-20T21:05:56  -    -       

[ok][2023-12-20 22:33:47]
```

Both components have reached the `ready` state, meaning the nano service plan
has completed all required work. The `base-config-created` state was reached a
couple of seconds after `device-automaton-created` which is expected. Recall
that the `base-config-created` state includes a pre-condition that monitors the
`device-ready` leaf in the automaton service. The leaf is only set to `true`
after the automaton has completed its initial device onboarding process, which
takes some time even for a local netsim device.

Finally you can verify that the device was configured as expected by checking
the configuration modified by the `base-config-created` state. With the NSO CLI
command `request nodes cpe test plan component cpe test state
base-config-created get-modifications` you can read the effects of the service
create callback for that state:

```shell
request nodes cpe test plan component cpe test state base-config-created get-modifications
```

Output:
```
admin@ncs> request nodes cpe test plan component cpe test state base-config-created get-modifications 
cli {
    local-node {
        data  devices {
                   device test {
                       config {
              +            hostname test;
                       }
                   }
               }
               rfs {
              +    base-config test {
              +        hostname test;
              +    }
               }
    }
}
```

Note: The `get-modifications` action reads the so called "service forward diff"
which is only available if the `/services/global-settings/collect-forward-diff`
leaf is set to `true`.

## Summary

In this learning lab you have learned how to create a truly declarative service
in NSO that not only provides device with configuration but also onboards the
device in NSO. But the story does not end here. The node service itself is a
building block for creating complex customer facing services (CFS) that span
multiple devices. For example, a L3VPN service could be implemented as a CFS
using the standard ietf-l3vpn-svc YANG model. The CFS would then use the node
services to configure the individual devices. The full service stack would then
look like this:

```
           ┌───────────────────────┐
           │ /l3vpn-svc:sites/site │
           └──────────┬────────────┘
                      │
           ┌──────────▼───────────┐
           │ /nodes/cpe           │
           └──┬─────────────────┬─┘
              │                 │
┌─────────────▼───────┐ ┌───────▼────────────┐
│ /devices/automaton  │ │ /rfs/base-config   │
└─────────────────────┘ └────────────────────┘
```

In this stacked service design the users external to NSO do not interact with
the node service directly. This is important because it honors the NSO design
requirement that the lower level services data (the node service and other RFSs)
shall not be modified "out-of-band", only through the high level CFS.

We hope you have enjoyed this lab and that you will leave inspired to build
awesome network automation solutions on your own!
