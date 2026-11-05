# server-setup

Put a Node.js app on a fresh Ubuntu server with one command. The script asks simple questions and does the rest, so no technical background is needed. Allow about 30 minutes.

**Already know your way around?** Create an Ubuntu server with ports 22, 80 and 443 open to `0.0.0.0/0`, connect to it, and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jaideepp247/server-setup/main/setup.sh)
```

Everyone else, follow the guide below.

- [Before you start](#before-you-start)
- [Part 1: Create the server](#part-1-create-the-server)
- [Part 2: Create a GitHub token](#part-2-create-a-github-token)
- [Part 3: Run the setup](#part-3-run-the-setup)
- [If something goes wrong](#if-something-goes-wrong)
- [Everyday commands](#everyday-commands)
- [For developers](#for-developers)

## Before you start

Have these ready:

- A login for AWS (or another cloud provider)
- The link to your app on GitHub
- The app's env file (its settings). Ask a developer if you don't have it.
- **Optional:** a Gitleaks license key, if you want secret scanning in automatic deploys
- **Optional:** a domain name, and access to where it is managed

## Part 1: Create the server

These steps are for AWS. Other providers are covered at the end of this part.

1. Sign in to AWS. In the top-right corner, choose the region closest to your users.
2. Search for **EC2** at the top of the page and open it. Click **Launch instance**.
3. **Name:** type something clear, such as `my-app-dev`.
4. **Application and OS Images:** choose **Ubuntu**, then **Ubuntu Server 24.04 LTS**.
5. **Instance type:** pick one from the table below. The Architecture must match it.

   | Instance type | Architecture to choose | Good for |
   |---|---|---|
   | `t4g.medium` | 64-bit (Arm) | Most apps. Lower cost. |
   | `t3.medium` | 64-bit (x86) | Most apps. Use this if an app has trouble on Arm. |
   | `t4g.small` | 64-bit (Arm) | Small, simple apps only. |

6. **Key pair:** click **Create new key pair**, give it a name, and create it. Keep the downloaded `.pem` file somewhere safe.
7. **Network settings:** click **Edit** if needed, and create a security group with these rules:

   | Type | Port | Source |
   |---|---|---|
   | SSH | 22 | `0.0.0.0/0` (Anywhere) |
   | HTTP | 80 | `0.0.0.0/0` (Anywhere) |
   | HTTPS | 443 | `0.0.0.0/0` (Anywhere) |

8. **Storage:** set it to **30 GB**.
9. Click **Launch instance** and wait until its state says **Running**.

### Give the server a permanent address

Without this, the server's address changes if it is stopped, and your domain and automatic deploys stop working.

1. In EC2, open **Elastic IPs** in the left menu and click **Allocate Elastic IP address**, then **Allocate**.
2. With the new address selected, click **Actions**, then **Associate Elastic IP address**.
3. Choose your instance and click **Associate**.

### Using a different cloud provider?

The steps are similar. Create a server with Ubuntu 24.04, about 2-4 GB of memory and 30 GB of disk, open ports 22, 80 and 443 to everyone, and give it a fixed IP address.

| Provider | The server is called | Fixed IP is called |
|---|---|---|
| Google Cloud | Compute Engine VM | Static external IP |
| Microsoft Azure | Virtual Machine | Static public IP |
| DigitalOcean | Droplet | Reserved IP |

## Part 2: Create a GitHub token

A token is like a temporary password that lets the setup get your code. It's only used while the setup runs and isn't saved on the server.

1. On GitHub, click your profile picture, then **Settings**.
2. At the bottom of the left menu, click **Developer settings**.
3. Click **Personal access tokens**, then **Fine-grained tokens**, then **Generate new token**.
4. Give it a name and set the expiry to **7 days**.
5. **Resource owner:** choose the company or account that owns the repo.
6. **Repository access:** choose **Only select repositories** and pick your repo.
7. Under **Permissions**, add these three and set each one to **Read and write**: **Contents**, **Secrets**, **Workflows**.
8. Click **Generate token** and copy it straight away. GitHub shows it only once.

> **Company repos:** an organization owner may need to approve the token before it works.

## Part 3: Run the setup

1. In EC2, open **Instances**, select your server and click **Connect**.
2. Open the **EC2 Instance Connect** tab, make sure the username is **ubuntu**, and click **Connect**. A black terminal window opens in your browser.
3. Copy the command below, paste it into that window, and press **Enter**.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jaideepp247/server-setup/main/setup.sh)
```

> **Pasting in the terminal:** use **Ctrl+Shift+V** on Windows, or **Cmd+V** on Mac. Tokens and keys stay invisible while you paste them. That's normal: paste once and press Enter.

Answer the questions as they appear. Here is what happens:

| Step | What it does | What you do |
|---|---|---|
| 1. Install | Installs Node 24, npm, yarn and pm2. | Just wait a few minutes. |
| 2. Get code | Downloads your app from GitHub. | Paste the repo link and token. Type the branch, such as `dev`, or press Enter for the repo's main branch. |
| 3. Settings | Saves your env file. | Paste the whole file, press Enter, type `END`, press Enter. Check the list of names and press Enter. |
| 4. Build | Finds the right commands and builds the app. | Press Enter to accept the commands. Wait. |
| 5. Start | Starts the app, finds its port and checks that it works. | Just wait. If it fails, you'll see the error and can paste the env file again. |
| 6. Auto deploy | Asks if you want automatic deploys. | Type `y` or `n`. For yes: paste the Gitleaks key or press Enter to skip, then press Enter to let it create the SSH key. |
| 7. Pipeline | Adds the deploy pipeline and secrets to GitHub. | Just wait. |
| 8. Domain | Connects your domain with HTTPS. | Type `y` or `n`. For yes: type the domain, then add the record it shows you at your domain provider. |

When you see **All done!**, the setup is finished. The screen shows your app's address.

> **No domain?** The app runs, but people can't open it yet, because only ports 80 and 443 are open. Run the setup command again later to connect a domain.

## If something goes wrong

It's always safe to run the setup command again. It updates the existing app and doesn't duplicate anything.

| What you see | What to do |
|---|---|
| This server is not Ubuntu | Create a new server and choose Ubuntu in Part 1. |
| GitHub refused access | Check the repo link. Check that the token hasn't expired and that it includes this repo. |
| The branch doesn't exist | Check the branch name on GitHub. Capital letters matter. |
| The app is not working yet | Read the message under it. Usually an env value is wrong or missing. Choose option 1 and paste the corrected env file. |
| Ran out of memory | Your server is too small. Create a larger one, such as `t3.medium`. |
| This token can't manage this repo's secrets | Go back to Part 2 and check all three permissions. Create a new token and paste it. |
| The domain isn't set up yet | Add the A record exactly as shown, wait a few minutes, and press Enter to check again. |
| The domain isn't answering yet | Check that ports 80 and 443 are open (Part 1). If you use Cloudflare, set the record to DNS only (grey cloud). |
| The terminal window closed | Reconnect (Part 3) and run the command again. |
| Anything else | Send a developer the error on screen and the file `server-setup.log` from the home folder. |

## Everyday commands

Connect to the server (Part 3) and type one of these, replacing `my-app` with your repo's name.

See whether the app is running:

```bash
pm2 status
```

See the app's messages (press Ctrl+C to leave):

```bash
pm2 logs my-app
```

Restart the app:

```bash
pm2 restart my-app
```

> **Finished with a server?** Terminate the instance and release its Elastic IP in AWS, so you stop paying for them.

## For developers

### Requirements

- Ubuntu (24.04 recommended) with `sudo` access
- A Node.js app with `package.json` in the repo's main folder
- A GitHub token, unless the repo is public and you skip CI/CD. Without CI/CD, read-only **Contents** access is enough.

### How commands are chosen

| Item | Rule |
|---|---|
| Package manager | `packageManager` in `package.json`, then the lockfile, then yarn |
| Build | The `build` script, if there is one |
| Start | The first of `start:prod`, `start:production`, `prod`, `start`, `serve`, `preview` |

These can be changed at the prompt before anything runs.

### What it sets up

| Item | Location |
|---|---|
| App | `~/<repo-name>` |
| Env file | `~/<repo-name>/.env` (readable by your user only) |
| pm2 process | Named after the repo, restarts with the server |
| Pipeline | `.github/workflows/staging.yml` in your repo |
| GitHub secrets | `DEV_HOST`, `DEV_USERNAME`, `DEV_SSH_KEY`, `GITLEAKS_LICENSE` |
| Caddy site | `/etc/caddy/sites/<repo-name>.caddy` |
| Setup log | `~/server-setup.log` |

### Security

- The GitHub token stays in memory while the script runs. It isn't saved on the server.
- An SSH key created by the script goes into GitHub secrets, and its private half is then removed from the server.
- Env values are never written to the setup log.
- Port 22 is open to the internet because GitHub's deploy runners don't use fixed IP addresses. Login is by SSH key only.
