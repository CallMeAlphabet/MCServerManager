# LeafMC Server Manager

## Backstory
A friend once bet me an 8GB DDR4 RAM stick and access to a 20-core Minecraft server if I could set up a LeafMC server in under 5 minutes. I said "no" about ten times. With RAM prices being what they are (or were), the odds of him actually following through seemed close to zero. But eventually, I took the challenge, opened my terminal, fired up a server and got it done (then deleted the server right after).

That experience got me thinking: why not automate this? So I built a simple bash script to create, backup, delete, and manage LeafMC servers and decided to make it public for anyone who needs it. Or lands in a situation like me ;)

## How to install

1. Install openjdk-21-jdk (or the corresponding package on your system) if you haven't already
2. Verify
```bash
java --version
```
3. Create directory where we'll put LeafMC
```bash
sudo mkdir -p /opt/leafmc
```
4. Make sure you own the directory
```bash
sudo chown -r $USER:$USER /opt/leafmc
```
5. Install this script
```bash
git clone https://raw.githubusercontent.com/CallMeAlphabet/LeafMCManager/refs/heads/master/server.sh /opt/leafmc/
```
6. Make it executable
```bash
chmod +x /opt/leafmc/server.sh
```
7. Run it!
```bash
/opt/leafmc/server.sh
