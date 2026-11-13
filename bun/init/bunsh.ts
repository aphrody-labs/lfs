#!/usr/bin/bun
// bunsh: the bun-LFS login shell. Each line runs through Bun's built-in shell (Bun.$),
// which provides pipes, redirections, globbing and builtins without /bin/sh.
// Usage: bunsh            interactive
//        bunsh -c "cmd"   one command (what WSL and `su -c` expect from a login shell)
// Plain JS syntax on purpose: installed as the extensionless /usr/bin/bunsh.
const run = async (line) => {
  const r = await Bun.$`${{ raw: line }}`.nothrow();
  return r.exitCode;
};

const argv = process.argv.slice(2);
if (argv[0] === "-c" && argv[1] !== undefined) {
  process.exit(await run(argv[1]));
}

const prompt = () => process.stdout.write(`bunsh:${process.cwd()}# `);
prompt();
for await (const line of console) {
  const cmd = line.trim();
  if (cmd === "exit" || cmd === "logout") break;
  if (cmd.startsWith("cd ")) {
    try {
      process.chdir(cmd.slice(3).trim());
    } catch (e) {
      console.error(String(e));
    }
  } else if (cmd) {
    await run(cmd);
  }
  prompt();
}
