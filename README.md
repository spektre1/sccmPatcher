# sccmPatcher
A system to remotely patch tens of thousands (or more) of Windows systems in an SCCM environment using PowerShell

This was originally built in a large enterprise environment so I could actively monitor
the patching operation while it's going. The script is setup to use a
Master->Proxy->Endpoint architecture. It uses active PSRemote sessions from proxy hosts
to command the endpoints to walk through their patching. Currently, this means state is
on the proxies to spread the computation load. I was planning on centralizing it better
in a third party backend before the project was pulled.

Bear in mind that this was meant to be glue code between Microsoft and a large automation
platform for an enterprise environment, so it won't make much sense for you otherwise. I
keep it as reference for patching problems, as there's a lot of good solutions in here.

Requires:
* SCCM
* WSUS

Pros:
* Active sessions means you can include inline remediations for patching issues

