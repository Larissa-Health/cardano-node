# Cardano RTView

> Attention: RTView is hidden behind a build flag. Enable with this cabal flag: `-f +rtview`.

RTView is an optional part of `cardano-tracer` [service](https://github.com/intersectmbo/cardano-node/blob/master/cardano-tracer/docs/cardano-tracer.md). It is a real-time monitoring tool for Cardano nodes (RTView is an abbreviation for "Real Time View"). It provides an interactive web page where you can see different kinds of information about connected nodes.

RTView is not feature complete and is thus disabled by default. Being
an experimental/optional component of `cardano-tracer` we will still
guarantee it remains buildable and usable in its current state.

# Contents

1. [Introduction](#introduction)
   1. [Motivation](#motivation)
   2. [Overview](#overview)
2. [TL;DR: Quick Start](#tldr-quick-start)
3. [Configuration](#configuration)
4. [Notifications](#notifications)
   1. [SMTP settings](#smtp-settings)
   2. [Note for Gmail users](#note-for-gmail-users)
   3. [Events](#events)
   4. [Notify period](#notify-period)
5. [UI](#ui)
   1. [Security Alert](#security-alert)
   2. [Missing Metrics](#missing-metrics)
   3. [Producer or Relay?](#producer-or-relay)

# Introduction

## Motivation

For a long time, Stake Pool Operators used third-party tools for monitoring their Cardano nodes, such as [Grafana](https://grafana.com/grafana/dashboards/12469)-based installations. These third-party solutions work, but they have two main problems:

1. Complex setup, especially for non-technical person.
2. Limited kinds of displayed information. For example, metrics can be shown, but error messages cannot.

RTView solves both of them:

1. Its setup is as simple as possible: if you have `cardano-tracer` installed, you already have RTView.
2. Because of using special network protocols integrated into the node, RTView can display any information that the node can provide.

## Overview

You can think of RTView as a SPA (Single Page Application) that can be opened in any modern browser. All the information on it changes dynamically, so you shouldn't refresh it.

When you open it for the first time, you'll see a help message about required configuration.

After your node connects to `cardano-tracer`, you'll see a column with different information, such as the node's name, version, protocol, era, sync percentage, KES values, blockchain info, etc. There is a separate column for each connected node, so you can see and compare their data.

Also, there are dynamic charts for different metrics, such as system metrics, blockchain metrics, transaction metrics, etc.

# TL;DR: Quick Start

If you just want to see what is RTView in action - all you need is following simple steps. For simplicity, it is assumed that `cardano-tracer` and your node will run on the same machine with Unix-like OS (for example, Linux).

## Tracer's Side

First of all, take configuration file `minimal-example-rtview.json` from `cardano-tracer/configuration` directory.

Next, run `cardano-tracer` with this configuration file like this:

```
$ ./cardano-tracer -c minimal-example-rtview.json
```

## Node's Side

Now, open your node's configuration file (if you took it from the [Cardano World Repository](https://book.world.dev.cardano.org/environments.html), it's `config.json`) and add the following lines in it:

```
"UseTraceDispatcher": true,
"TraceOptions": {
  "": {
    "severity": "Notice",
    "detail": "DNormal",
    "backends": [
      "Stdout MachineFormat",
      "EKGBackend",
      "Forwarder"
    ]
  }
},
"TraceOptionPeerFrequency": 2000,
"TraceOptionResourceFrequency": 5000,
"TurnOnLogMetrics": false,
"TraceOptionNodeName": "relay-1"
```

Please make sure you specified the _real name_ of your node in `TraceOptionNodeName` field.

Finally, run the node with this configuration file and add tracer's CLI-parameter like this:

```
$ ./cardano-node run --tracer-socket-path-connect /tmp/forwarder.sock
```

That's it. Now you can open [https://127.0.0.1:3300](https://127.0.0.1:3300/) in your browser.

### Important

Please note that the node has another CLI-parameter for the socket:

```
--socket-path FILEPATH   Path to a cardano-node socket
```

But `--socket-path` is **not** for working with `cardano-tracer`. The only CLI-parameters you need to specify the path to the socket for working with `cardano-tracer` are `--tracer-socket-path-connect` (if your node should _initiate_ connection) or `--tracer-socket-path-accept` (if your node should _accept_ connection). They are **not** related to `--socket-path`, so you can use these CLI-parameters independently from each other.

# Configuration

Since RTView is a part of `cardano-tracer`, the only thing you need to do is to enable RTView (because it's disabled by default). To do it, please add the following lines to `cardano-tracer`'s configuration file.

If you use `json`-configuration:

```
"hasRTView": {
  "epHost": "127.0.0.1",
  "epPort": 3300
}
```

Or, if you use `yaml`-configuration:

```
hasRTView:
  epHost: 127.0.0.1
  epPort: 3300
```

Here `epHost` and `epPort` specify the host and the port for RTView web page. Also, you can find examples of configuration files in [configuration directory](https://github.com/intersectmbo/cardano-node/tree/master/cardano-tracer/configuration).

That's it. Now run `cardano-tracer` and open [127.0.0.1:3300](https://127.0.0.1:3300) in your browser.

# Notifications

RTView can send notifications about specified events (for example, warnings or errors). Click on the bell icon on the top bar to see the corresponding settings.

## SMTP settings

Technically, RTView contains an email client that sends emails using SMTP. That's why you need the SMTP settings of your email provider. Please fill in all the inputs marked with an asterisk in `Settings` window.

You can use `Send test email` button to check if your email settings are correct.

## Note for Gmail users

If you want to set up email notifications using your Gmail account, please make sure that `2-Step Verification` is enabled. You can check it in `Google Account` -> `Security`. After you enabled `2-Step Verification`, please generate the new app password (if you don't have one already) in `Security` -> `App passwords`. You'll need this app password for RTView settings.

Now you can set up RTView notifications:

1. `SMTP host`: `smtp.gmail.com`

2. `SMTP port`: `587`

3. `Username`: most likely, it's your email address

4. `Password`: app password you've generated

5. `SSL`: `STARTTLS`

## Events

When you click on the bell icon on the top bar, you can open `Events` window. Here you can specify events you want to be notified about.

For example, let's have a look at `Warnings` (i.e. all the messages from the node with `Warning` severity level). By default, the corresponding switch is disabled, which means that you won't be notified about warnings at all. But if you enable that switch, you will periodically receive a notification about warnings, if any.

You can use a switch `All events` in the bottom of the window to enable/disable all the events at once. Please note that if you disable all the events, the bell icon on the top bar becomes "slashed".

## Notify period

You can specify how frequently you want to receive notifications for a specific event. To do it, select a value from the dropdown list at the right of the event switch. There are values from `Immediately` to `Every 12 hours`.

If you selected `Immediately`, the new email with the associated event(s) will be sent right away. It can be used for critical events: most likely, you want to know about such events as soon as possible.

If you selected `Every 12 hours`, the new email with associated event(s) will be sent only two times a day. I can be used for non-critical events, like `Warnings`.

# UI

## Security Alert

When you open the web page for the first time, you'll see a warning from your browser, something like "Potential Security Risk Ahead" or "Your connection is not private". This is because `https`-connection between your browser and RTView is using [self-signed certificate](https://en.wikipedia.org/wiki/Self-signed_certificate) generated by [openssl](https://www.openssl.org/) program. So click to `Advanced` button and open the page. Technically, there is no risk at all - your connection **is** private.

## Missing Metrics

When the node connects to `cardano-tracer` and RTView's page displays the first data from it, you may see that some other data is missing: there is `—` instead of particular value. There are following possible reasons for it:

1. The node didn't provide corresponding metrics _yet_, because some information (for example, sync percent) can be displayed only after few minutes after node's start.
2. The node _cannot_ provide corresponding metrics. For example, forging-related metrics make sense only for producer node, not for relay node.
3. The node doesn't provide corresponding metrics because of node's configuration. For example, it can specify severity filter for particular metric, so it just filtered out.
4. The node is incompatible with `cardano-tracer` (they were built from different branches of `cardano-node` repository). For example, particular metric may be renamed in the node, but `cardano-tracer` is still using outdated name.

## Producer or Relay?

If the node is configured as a _producer_ - i.e. it can forge the new blocks - you will see a hammer icon near the node's name. So, there are two possible reasons if you don't see this hammer icon:

1. The node is configured as a relay, not as a producer.
2. The node is not reported about its "producer status" yet.
