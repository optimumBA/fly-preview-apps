const core = require("@actions/core");
const github = require("@actions/github");
const { spawn } = require("node:child_process");
const fs = require("fs");

const spawnCommand = (command, args) => {
  console.log(command, args);
  let p = spawn(command, args, {
    stdio: "inherit",
    shell: true,
  });
  return new Promise((resolveFunc) => {
    p.on("exit", (code) => {
      resolveFunc(code);
    });
  });
};

const flyctl = (commandArgs) => spawnCommand("flyctl", commandArgs);

const exitIfFailed = async (func) => {
  const result = await func();
  if (result != 0) {
    process.exit(45);
  }
  return result;
};

async function run() {
  try {
    const inputPath = core.getInput("path");
    const name = core.getInput("name");
    const region = core.getInput("region");
    const postgres = core.getInput("postgres");
    const org = core.getInput("org");
    const image = core.getInput("image") ? core.getInput("image") : "";
    const update = core.getInput("update") == "true" ? true : false;
    const config = core.getInput("config");

    if (inputPath) {
      process.chdir(inputPath);
    }

    const context = github.context;
    const owner = context.repo.owner;
    const repo = context.repo.repo;
    const eventType = context.action;
    console.log("Run number: ", context.runNumber);
    console.log("Issue number: ", context.issue.number);
    const prNumber = context.issue.number;

    const app = name ? name : `pr-${prNumber}-${owner}-${repo}`;

    await spawnCommand("curl", [
      "-L",
      "https://fly.io/install.sh",
      "|FLYCTL_INSTALL=/usr/local sh ",
    ]);

    if (eventType == "closed") {
      await flyctl(["apps", "destroy", app]);
      process.exit(45);
    }

    const status_r = await flyctl(["status", "--app", app]);
    if (status_r != 0) {
      //Deploy the Fly app, creating it first if needed.
      await exitIfFailed(() =>
        flyctl([
          "launch",
          "--no-deploy",
          "--copy-config",
          `--name "${app}"`,
          '--image ""',
          `--region "${region}"`,
          `--org "${org}"`,
        ])
      );

      // TODO: handle INPUT_SECRETS

      if (postgres) {
        await exitIfFailed(() =>
          flyctl(["postgres", "attach", `"${postgres}"`])
        );
      }

      await exitIfFailed(() =>
        flyctl([
          "deploy",
          `--app "${app}"`,
          `--region "${region}"`,
          `--image "${image}"`,
          `--region "${region}"`,
          "--strategy immediate",
        ])
      );
    } else if (update) {
      await exitIfFailed(() =>
        flyctl([
          "deploy",
          `--config "${config}"`,
          `--app "$app"`,
          `--region "${region}"`,
          `--image "${image}"`,
          `--region "${region}"`,
          `--strategy immediate`,
        ])
      );
    }

    await flyctl(["status", `--app "${app}"`, `--json`, `>status.json`]); // or exit
    const status = JSON.parse(fs.readFileSync("status.json"));

    core.setOutput("hostname", status.Hostname);
    core.setOutput("url", `https://${status.Hostname}`);
    core.setOutput("id", status.ID);
  } catch (error) {
    core.setFailed(error.message);
  }
}
run();
