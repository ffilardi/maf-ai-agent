# Getting Started

There are 3 options for getting started:

1. Run the template virtually by using [GitHub Codespaces](#github-codespaces), which sets up tools automatically (quickest way).
2. Run in your local VS Code using the [VS Code Dev Containers](#vs-code-dev-containers) extension.
3. Setting-up a [Local Environment](#local-environment) (MacOS, Linux or Windows).

Both Codespaces and Dev Containers share the same [`.devcontainer`](../.devcontainer/) definition, so the environment is identical either way. It provisions the **.NET 10 SDK** (backend), **Node.js 20** (frontend), plus `az`, `azd`, and Bicep. On create, [`install-requirements.sh`](../.devcontainer/install-requirements.sh) runs `dotnet restore` on every `src/*/*.csproj` and `npm install` on every `src/*/package.json`, so both tiers are ready to run — ports **8000** (backend) and **5173** (frontend) are labelled and auto-forwarded.

## GitHub Codespaces

Prerequisites:
- Azure subscription with permissions to create resource groups and deploy resources.
- GitHub account.

Steps:
1. Open the repository in [GitHub Codespaces](https://codespaces.new/ffilardi/maf-ai-agent)
2. Configure the settings and create the Codespace (this may take several minutes)

## VS Code Dev Containers

Prerequisites:
- Azure subscription with permissions to create resource groups and deploy resources.
- [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) for VS Code
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) 

Steps:
1. Start Docker Desktop
2. Open the project in a [VS Code Dev Container](https://vscode.dev/redirect?url=vscode://ms-vscode-remote.remote-containers/cloneInVolume?url=https://github.com/ffilardi/maf-ai-agent) (this may take several minutes)

## Local Environment

Prerequisites:
- Azure subscription with permissions to create resource groups and deploy resources.
- Install [Azure Developer CLI](https://aka.ms/install-azd)
    - Windows: `winget install microsoft.azd`
    - Linux: `curl -fsSL https://aka.ms/install-azd.sh | bash`
    - MacOS: `brew tap azure/azd && brew install azd`
- Install [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) for the backend agent
- Install [Node.js 20+](https://nodejs.org/) for the frontend SPA (Vite + React)
- Install [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) for advanced scenarios (optional)

Steps:
1. Clone the repository locally:
    ```shell
    git clone <repository-url>
    cd <repository-folder>
    ```

2. Restore dependencies:
   ```shell
   # Backend (.NET)
   dotnet restore src/agent_backend/AgentBackend.csproj
   # Frontend (Node)
   npm --prefix src/agent_frontend install
   ```

3. Open VS Code and load the local project folder

## Working against the provisioned resources

Foundry, Azure AI Search, and Storage are all provisioned with **key-based access disabled**, and Cosmos DB is
reached with Entra ID rather than its account key: the app reaches
Foundry and Search only through APIM (which injects its own managed identity), and reaches Storage with the
App Service's managed identity. That closes the paths around the gateway — and it means an account key or an
admin key will no longer get *you* in either.

### Running the backend locally

`dotnet run` authenticates with `DefaultAzureCredential`, which picks up your `az login` — but your principal
starts with no data-plane roles. Storage and Cosmos are the services the backend talks to with that credential
(model, search, Document Intelligence, and Content Safety all go through APIM with the subscription key), so grant
yourself the same roles the App Service holds, once per environment:

```shell
me=$(az ad signed-in-user show --query id -o tsv)
scope=$(az storage account show -g <rg-common-...> -n <storage-account-name> --query id -o tsv)

for role in "Storage Blob Data Contributor" "Storage Queue Data Contributor" "Storage Table Data Contributor"; do
  az role assignment create --assignee "$me" --role "$role" --scope "$scope"
done

# Cosmos keeps documents behind its own SQL role system — Azure RBAC roles grant no data access at all.
az cosmosdb sql role assignment create \
  -g <rg-common-...> -a <cosmos-account-name> \
  --role-definition-id 00000000-0000-0000-0000-000000000002 \
  --principal-id "$me" --scope "/"
```

`COSMOS_USE_RBAC=false` plus a `COSMOS_KEY` is the rollback if you need it, and it works only while the account
still accepts keys (see below).

### Turning Cosmos keys off

`disableCosmosLocalAuth` in `infra/main.bicep` defaults to **false**, and turning it on takes **two passes**: the
first `azd provision` creates the backend's Cosmos DB Data Contributor assignment, and only a later provision may
disable keys. Doing both in one pass can wedge the deployment and lock the app out of its own data. Once the app
is confirmed working over RBAC, add the parameter to `infra/main.parameters.json` and provision again:

```json
"disableCosmosLocalAuth": { "value": true }
```

### Browsing the resources in the portal

- **Storage** — the account defaults to Entra authorization; Storage Explorer and the portal's blob browser must
  be switched from "Access key" to "Microsoft Entra user account". The roles above cover it.
- **Search** — Search Explorer's authentication toggle has to be set to Entra, and your principal needs
  **Search Index Data Reader** on the service to read the index:
  ```shell
  az role assignment create --assignee "$me" --role "Search Index Data Reader" \
    --scope $(az search service show -g <rg-ai-...> -n <search-service-name> --query id -o tsv)
  ```
  Reviewing a single flagged chunk doesn't need this — that path goes through APIM (see
  [`rag.md`](rag.md#reviewing-a-flagged-passage)).
- **Cosmos** — Data Explorer needs the same SQL role as above; the account's *Keys* blade is unused by the app.
- **Foundry** — the account's *Keys and Endpoint* blade shows keys as disabled. The playground authenticates with
  your Entra identity; `Cognitive Services User` on the account is what it needs.
