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