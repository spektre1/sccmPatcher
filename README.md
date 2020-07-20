# sccmPatcher
A system to remotely patch tens of thousands (or more) of Windows systems in an SCCM environment using PowerShell

This was originally built in a large enterprise environment so I could actively monitor
the patching operation while it's going. The script is setup to use a
Master->Proxy->Endpoint architecture. It uses active PSRemote sessions from proxy hosts
to command the endpoints to walk through their patching. Currently, this means state is
on the proxies to spread the computation load. I was planning on centralizing it better
in a third party backend before the project was pulled.

In my testing (circa 2017) the proxies could handle approx 30-50 live sessions. I modify
the subshell launches to limit mem usage, which makes it easier to run more. 

Bear in mind that this was meant to be glue code between Microsoft code and a large
automation platform for an enterprise environment, so it won't make much sense for you
otherwise. I keep it as reference for patching problems, as there's a lot of good
solutions in here.

If I were to approach this now, I'd probably setup a message bus of some sort instead.
I'd consider side-loading a script into the endpoints that could subscribe to the bus,
and do a complete cleanup on itself after.

Requires:
* SCCM
* WSUS

Pros:
* Active sessions means you can include inline remediations for patching issues
* Easy to understand code (I hope)

Cons
* Need a lot of proxies, far less than optimal command and control channel utilization
* I mean, it's Windows
