"""Builds Server-Setup-Instructions.pdf. Run: python make_instructions_pdf.py (needs reportlab)."""
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import (KeepTogether, ListFlowable, ListItem, Paragraph, SimpleDocTemplate,
                                Spacer, Table, TableStyle)

COMMAND = "bash <(curl -fsSL https://raw.githubusercontent.com/jaideepp247/server-setup/main/setup.sh)"
OUT = Path(__file__).with_name("Server-Setup-Instructions.pdf")

INK = colors.HexColor("#1f2933")
MUTED = colors.HexColor("#52606d")
ACCENT = colors.HexColor("#0b6e4f")
LINE = colors.HexColor("#d9dee3")
TINT = colors.HexColor("#f2f5f7")
NOTE = colors.HexColor("#fff6e0")
CODE_BG = colors.HexColor("#1f2933")

body = ParagraphStyle("body", fontName="Helvetica", fontSize=10.5, leading=15, textColor=INK, alignment=TA_LEFT, spaceAfter=5)
small = ParagraphStyle("small", parent=body, fontSize=9.5, leading=13, spaceAfter=0)
title = ParagraphStyle("title", fontName="Helvetica-Bold", fontSize=23, leading=28, textColor=INK, spaceAfter=4)
sub = ParagraphStyle("sub", parent=body, fontSize=11.5, leading=16, textColor=MUTED, spaceAfter=12)
h1 = ParagraphStyle("h1", fontName="Helvetica-Bold", fontSize=14.5, leading=19, textColor=ACCENT, spaceBefore=14, spaceAfter=6)
h2 = ParagraphStyle("h2", fontName="Helvetica-Bold", fontSize=11, leading=15, textColor=INK, spaceBefore=8, spaceAfter=3)
th = ParagraphStyle("th", parent=small, fontName="Helvetica-Bold")
code = ParagraphStyle("code", fontName="Courier-Bold", fontSize=8, leading=12, textColor=colors.white)

W = A4[0] - 40 * mm


def P(text, style=body):
    return Paragraph(text, style)


def steps(items):
    return ListFlowable([ListItem(P(i), leftIndent=16) for i in items], bulletType="1", bulletFontName="Helvetica-Bold",
                        bulletFontSize=10, bulletColor=ACCENT, leftIndent=16, start=1)


def bullets(items):
    return ListFlowable([ListItem(P(i), leftIndent=14) for i in items], bulletType="bullet", start="•", leftIndent=14)


def box(content, bg, pad=7):
    t = Table([[content]], colWidths=[W])
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), bg), ("LEFTPADDING", (0, 0), (-1, -1), 9),
                           ("RIGHTPADDING", (0, 0), (-1, -1), 9), ("TOPPADDING", (0, 0), (-1, -1), pad),
                           ("BOTTOMPADDING", (0, 0), (-1, -1), pad)]))
    return t


def note(text):
    return box(P(text, small), NOTE)


def command(text):
    return box(P(escape(text), code), CODE_BG, 9)


def table(rows, widths):
    data = [[P(c, th) for c in rows[0]]] + [[P(c, small) for c in r] for r in rows[1:]]
    t = Table(data, colWidths=[w * W for w in widths], repeatRows=1)
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, 0), TINT), ("LINEBELOW", (0, 0), (-1, -1), 0.5, LINE),
                           ("VALIGN", (0, 0), (-1, -1), "TOP"), ("TOPPADDING", (0, 0), (-1, -1), 5),
                           ("BOTTOMPADDING", (0, 0), (-1, -1), 6), ("LEFTPADDING", (0, 0), (-1, -1), 6)]))
    return t


s = []
s += [P("Put your app on a server", title),
      P("A step-by-step guide. No technical background needed. Allow about 30 minutes.", sub)]

s += [P("Before you start", h1), P("Have these ready:"),
      bullets(["A login for AWS (or another cloud provider).",
               "The link to your app on GitHub.",
               "The app's env file (its settings). Ask a developer if you don't have it.",
               "<b>Optional:</b> a Gitleaks license key, if you want secret scanning in automatic deploys.",
               "<b>Optional:</b> a domain name, and access to where it is managed."])]

s += [P("Part 1: Create the server", h1),
      P("These steps are for AWS. Other providers are listed at the end of this part."),
      steps(["Sign in to AWS. In the top-right corner, choose the region closest to your users.",
             "Search for <b>EC2</b> at the top of the page and open it. Click <b>Launch instance</b>.",
             "<b>Name:</b> type something clear, such as <i>my-app-dev</i>.",
             "<b>Application and OS Images:</b> choose <b>Ubuntu</b>, then <b>Ubuntu Server 24.04 LTS</b>.",
             "<b>Instance type:</b> use the table below. The Architecture must match it.",
             "<b>Key pair:</b> click <b>Create new key pair</b>, give it a name, and create it. "
             "Keep the downloaded <b>.pem</b> file somewhere safe.",
             "<b>Network settings:</b> click <b>Edit</b> if needed, and create a security group with these rules:"])]
s += [Spacer(1, 4),
      table([["Type", "Port", "Source"], ["SSH", "22", "0.0.0.0/0 (Anywhere)"], ["HTTP", "80", "0.0.0.0/0 (Anywhere)"],
             ["HTTPS", "443", "0.0.0.0/0 (Anywhere)"]], [.3, .2, .5]),
      Spacer(1, 6),
      P("8. <b>Storage:</b> set it to <b>30 GB</b>."),
      P("9. Click <b>Launch instance</b> and wait until its state says <b>Running</b>."),
      Spacer(1, 2),
      KeepTogether([P("Which instance type?", h2),
                    table([["Instance type", "Architecture to choose", "Good for"],
                           ["t4g.medium", "64-bit (Arm)", "Most apps. Lower cost."],
                           ["t3.medium", "64-bit (x86)", "Most apps. Use this if an app has trouble on Arm."],
                           ["t4g.small", "64-bit (Arm)", "Small, simple apps only."]], [.27, .3, .43])])]

s += [KeepTogether([P("Give the server a permanent address", h2),
                    P("Without this, the server's address changes if it is stopped, and your domain and automatic deploys stop working."),
                    steps(["In EC2, open <b>Elastic IPs</b> in the left menu and click <b>Allocate Elastic IP address</b>, then <b>Allocate</b>.",
                           "With the new address selected, click <b>Actions</b>, then <b>Associate Elastic IP address</b>.",
                           "Choose your instance and click <b>Associate</b>."])])]

s += [KeepTogether([P("Using a different cloud provider?", h2),
                    P("The steps are similar. Create a server with Ubuntu 24.04, about 2-4 GB of memory and 30 GB of disk, "
                      "open ports 22, 80 and 443 to everyone, and give it a fixed IP address."),
                    table([["Provider", "The server is called", "Fixed IP is called"],
                           ["Google Cloud", "Compute Engine VM", "Static external IP"],
                           ["Microsoft Azure", "Virtual Machine", "Static public IP"],
                           ["DigitalOcean", "Droplet", "Reserved IP"]], [.3, .35, .35])])]

s += [P("Part 2: Create a GitHub token", h1),
      P("A token is like a temporary password that lets the setup get your code. It is only used while the setup runs and is not saved on the server."),
      steps(["On GitHub, click your profile picture, then <b>Settings</b>.",
             "At the bottom of the left menu, click <b>Developer settings</b>.",
             "Click <b>Personal access tokens</b>, then <b>Fine-grained tokens</b>, then <b>Generate new token</b>.",
             "Give it a name and set the expiry to <b>7 days</b>.",
             "<b>Resource owner:</b> choose the company or account that owns the repo.",
             "<b>Repository access:</b> choose <b>Only select repositories</b> and pick your repo.",
             "Under <b>Permissions</b>, add these three and set each one to <b>Read and write</b>: "
             "<b>Contents</b>, <b>Secrets</b>, <b>Workflows</b>.",
             "Click <b>Generate token</b> and copy it straight away. GitHub shows it only once."]),
      Spacer(1, 4),
      note("<b>Company repos:</b> an organization owner may need to approve the token before it works.")]

s += [P("Part 3: Run the setup", h1),
      steps(["In EC2, open <b>Instances</b>, select your server and click <b>Connect</b>.",
             "Open the <b>EC2 Instance Connect</b> tab, make sure the username is <b>ubuntu</b>, and click <b>Connect</b>. "
             "A black terminal window opens in your browser.",
             "Copy the command below, paste it into that window, and press <b>Enter</b>."]),
      Spacer(1, 4), command(COMMAND), Spacer(1, 6),
      note("<b>Pasting in the terminal:</b> use <b>Ctrl+Shift+V</b> on Windows, or <b>Cmd+V</b> on Mac. "
           "Passwords and tokens stay invisible while you paste them. That is normal: paste once and press Enter."),
      Spacer(1, 6),
      P("Answer the questions as they appear. Here is what happens:"),
      table([["Step", "What it does", "What you do"],
             ["1. Install", "Installs Node 24, npm, yarn and pm2.", "Just wait a few minutes."],
             ["2. Get code", "Downloads your app from GitHub.", "Paste the repo link and token. Type the branch, such as <b>dev</b>, or press Enter for the main branch."],
             ["3. Settings", "Saves your env file.", "Paste the whole file, press Enter, type <b>END</b>, press Enter. Check the list of names and press Enter."],
             ["4. Build", "Finds the right commands and builds the app.", "Press Enter to accept the commands. Wait."],
             ["5. Start", "Starts the app, finds its port and checks that it works.", "Just wait. If it fails, you'll see the error and can paste the env file again."],
             ["6. Auto deploy", "Asks if you want automatic deploys.", "Type <b>y</b> or <b>n</b>. For yes: paste the Gitleaks key or press Enter to skip, then press Enter to let it create the SSH key."],
             ["7. Pipeline", "Adds the deploy pipeline and secrets to GitHub.", "Just wait."],
             ["8. Domain", "Connects your domain with HTTPS.", "Type <b>y</b> or <b>n</b>. For yes: type the domain, then add the record it shows you at your domain provider."]],
            [.17, .39, .44]),
      Spacer(1, 6),
      P("When you see <b>All done!</b>, your app is live. The screen shows its address."),
      note("<b>No domain?</b> The app runs, but people can't open it yet, because only ports 80 and 443 are open. "
           "Run the setup command again later to connect a domain.")]

s += [P("If something goes wrong", h1),
      P("It is always safe to run the setup command again. It updates the existing app and doesn't duplicate anything."),
      table([["What you see", "What to do"],
             ["This server is not Ubuntu", "Create a new server and choose Ubuntu in Part 1."],
             ["GitHub refused access", "Check the repo link. Check that the token hasn't expired and that it includes this repo."],
             ["The branch doesn't exist", "Check the branch name on GitHub. Capital letters matter."],
             ["The app is not working yet", "Read the message under it. Usually an env value is wrong or missing. Choose option 1 and paste the corrected env file."],
             ["Ran out of memory", "Your server is too small. Create a larger one, such as t3.medium."],
             ["This token can't manage this repo's secrets", "Go back to Part 2 and check all three permissions. Create a new token and paste it."],
             ["The domain isn't set up yet", "Add the A record exactly as shown, wait a few minutes, and press Enter to check again."],
             ["The domain isn't answering yet", "Check that ports 80 and 443 are open (Part 1). If you use Cloudflare, set the record to DNS only (grey cloud)."],
             ["The terminal window closed", "Reconnect (Part 3) and run the command again."],
             ["Anything else", "Send a developer the error on screen and the file <b>server-setup.log</b> from the home folder."]],
            [.42, .58]),
      KeepTogether([P("Everyday commands", h1),
                    P("Connect to the server (Part 3) and type one of these, replacing <i>my-app</i> with your repo's name:"),
                    table([["Command", "What it does"], ["<font face='Courier'>pm2 status</font>", "Shows whether the app is running."],
                           ["<font face='Courier'>pm2 logs my-app</font>", "Shows the app's messages. Press Ctrl+C to leave."],
                           ["<font face='Courier'>pm2 restart my-app</font>", "Restarts the app."]], [.42, .58]),
                    Spacer(1, 6),
                    note("<b>Finished with a server?</b> Terminate the instance and release its Elastic IP in AWS, so you stop paying for them.")])]


def footer(canvas, doc):
    canvas.saveState()
    canvas.setFont("Helvetica", 8.5)
    canvas.setFillColor(MUTED)
    canvas.drawString(20 * mm, 11 * mm, "Put your app on a server")
    canvas.drawRightString(A4[0] - 20 * mm, 11 * mm, f"Page {doc.page}")
    canvas.restoreState()


SimpleDocTemplate(str(OUT), pagesize=A4, leftMargin=20 * mm, rightMargin=20 * mm, topMargin=18 * mm, bottomMargin=18 * mm,
                  title="Put your app on a server", author="Geeks of Kolachi").build(s, onFirstPage=footer, onLaterPages=footer)
print(OUT)
