# Infrastructure

This infrastructure contains the actual ScalePack infrastructure.

All remote based environment states are stored in the S3 bucket provisioned by `./00-remote_state`. Check `version.tf` files from any root module in this repository for an example, stored under eu-west-3 region.

## Forking

Forking support process coming soon.

## Onboarding

### Installation des dépendances

```bash
mise install
```

Cette commande installe toutes les dépendances du projet définies dans `mise.toml`.

### Installation des Git Hooks

```bash
.githooks/install.sh
```

Cela configure les git hooks locaux pour automatiser les vérifications avant les commits/pushes.

### Login with your credentials

> Skip 2 and more if you only need local environment. 1 is kept because right now, Infisical SSO features are PayGated, but allow long lived credentials within your environment. All hail long lived credentials! (Don't forget to look into your own local secret encryption solution to avoid storing them in clear. In my case, macOS built-in's `security` binary is enough. See https://dev.to/alsaheem/how-to-store-secrets-in-the-mac-keychain-and-use-them-like-environment-variables-1aj7).

1. Infisical

    Why Infisical? It's a free SSO organization solution for External Infrastructure Secrets. Will ultimately rely on External Secret Operator to synchronize over things. Somehow.
    1. Login to : https://app.infisical.com/login with SSO
    2. Create API_KEYS for your local environment.
    3. Create other long lived credentials you want for your infrastructure in this External Storage SaaS solution.

2. AWS as terraform remote backend solution : 

    Why AWS S3? It's extremely cheap, great DevX for mono storage management (fine grained IAM policies) and AWS includes free SSO setup for devops without friction. And Scaleway doesn't provide OIDC yet, which I do favor when it comes to CI runners, especially for such high-risk files.

    Run `aws sso login`. This needs to be done daily and at bootstrap before running any terraform command locally, or state fetch will fail. 

    #### AWS SSO first setup: 

    1. Go to https://d-806761a6d4.awsapps.com/start/#/

    2. Login with your credentials. Contact your manager or an admin if you didn't get one yet via email.

    3. Follow instructions for an AccessKey, and follow SSO setup instructions.

    Public documentation available here : https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html#sso-configure-profile-token-auto-sso

    
2. Scaleway as cloud provider
    > Scaleway is the current provider I want to use, because it offers :
        > 1. A cheap way to operate Kubernetes clusters without too many issues. I mean, I want to play with Kubernetes, and this GitHub org is my homelab. And I can have as many clusters as I want; as long as there's no node within, I won't pay. It's a great FinOps safeguard which I do want to take advantage of. Deal with it.
        > 2. As an EU citizen, I disapprove of the Cloud Act and any of those attacks against security, which in the end create a backdoor. I see those legalized actions as one. And yes, my supply chain includes storing extremely sensitive data in some of those companies (Infisical in free mode, Google, AWS...). At least I intend to use Scaleway, and have I told you about their DevX around Kubernetes managed service? It's within the EU, and not exposed to that, at least. That's my attempt toward sovereign data. With love <3

    #### Scaleway CLI/terraform bootstrap
    1. Log in with SSO with Scaleway : https://console.scaleway.com/organization

    2. Go to https://console.scaleway.com/iam/users

    3. Create an API KEY.

    4. [Optional] : I recommend one dedicated API KEY per tool. But unlike AWS, there is no rich default option with the Scaleway CLI that works out of the box, which is one of my requirements (passwordless/secretless CLI access for humans via SSO + passwordless/secretless for machines via OIDC). But, free kube, okay? Just grab your API keys — one for AWS, another for Terraform in external runtime contexts (kube, GitHub Actions, ...). This at least distinguishes local usage from "safe/legit" remote usage such as organization trusted runtimes. In the end, the more fine-grained, the better, but I'm not at that level yet :D

### Start playing

[WIP] This section will be added soon, and will explain how to start/stop the cluster nodes (and whatever makes me pay for something), in order to stop paying the bill, such as whenever I should sleep, or should not work. But right now, it's manual, and I will not explain it. Homelab, remember?
