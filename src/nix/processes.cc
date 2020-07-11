#include "command.hh"
#include "store-api.hh"
#include "pathlocks.hh"

#include <fstream>
#include <fcntl.h>

using namespace nix;

struct CmdProcesses : StoreCommand
{
    CmdProcesses()
    {
    }

    std::string description() override
    {
        return "show processes";
    }

    Examples examples() override
    {
        return {
            Example{
                "To show what processes are currently building:",
                "nix processes"
            },
        };
    }

    Category category() override { return catSecondary; }

    static std::optional<std::string> getCmdline(int pid)
    {
        auto cmdlinePath = fmt("/proc/%d/cmdline", pid);
        if (pathExists(cmdlinePath)) {
            string cmdline = readFile(cmdlinePath);
            string cmdline_;
            for (auto & i : cmdline) {
                if (i == 0) cmdline_ += ' ';
                else cmdline_ += i;
            }
            return cmdline_;
        }
        return std::nullopt;
    }

    static int fuser(Path path)
    {
        if (pathExists("/proc")) {
            for (auto & entry : readDirectory("/proc")) {
                if (entry.name[0] < '0' || entry.name[0] > '9')
                    continue;
                int pid;
                try {
                    pid = std::stoi(entry.name);
                } catch (const std::invalid_argument& e) {
                    continue;
                }
                if (pathExists(fmt("/proc/%d/fd", pid))) {
                    for (auto & fd : readDirectory(fmt("/proc/%d/fd", pid))) {
                        Path path2;
                        try {
                            path2 = readLink(fmt("/proc/%d/fd/%s", pid, fd.name));;
                        } catch (const Error & e) {
                            continue;
                        }
                        if (path == path2)
                            return pid;
                    }
                }
            }
            return -1;
        } else {
            int fds[2];
            if (pipe(fds) == -1)
                throw Error("failed to make fuser pipe");

            pid_t pid = fork();
            if (pid < 0)
                throw Error("failed to fork for fuser");

            if (pid == 0) {
                dup2(fds[1], fileno(stdout));
                dup2(open("/dev/null", 0), fileno(stderr));
                close(fds[0]); close(fds[1]);
                if (!execlp("fuser", "fuser", path.c_str(), NULL))
                    throw Error("failed to execute program fuser");
            }

            int status;
            waitpid(pid, &status, 0);
            if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
                throw Error("failed to execute fuser with status '%d'", status);
            char buffer[4096];
            ssize_t size = read(fds[0], &buffer, sizeof(buffer));
            try {
                return std::stoi(std::string(buffer, size));
            } catch (const std::invalid_argument& e) {
                return -1;
            }
        }
    }

    static int getPpid(int pid) {
        if (!pathExists(fmt("/proc/%d/status", pid)))
            return -1;
        std::fstream fs;
        fs.open(fmt("/proc/%d/status", pid), std::fstream::in);
        string line;
        while (std::getline(fs, line)) {
            if (hasPrefix(line, "PPid:\t")) {
                fs.close();
                try {
                    return std::stoi(line.substr(6));
                } catch (const std::invalid_argument& e) {
                    return -1;
                }
            }
        }
        fs.close();
        return -1;
    }

    static int printChildren(int pid) {
        int numChildren = 0;
        for (auto & entry : readDirectory("/proc")) {
            if (entry.name[0] < '0' || entry.name[0] > '9')
                continue;
            int childPid;
            try {
                childPid = std::stoi(entry.name);
            } catch (const std::invalid_argument& e) {
                continue;
            }
            if (getPpid(childPid) == pid) {
                numChildren++;
                bool hasChildren = printChildren(childPid) > 0;
                if (!hasChildren) {
                    auto cmdline = getCmdline(childPid);
                    if (cmdline && !cmdline->empty())
                        std::cout << fmt("Child Process: %s", *cmdline) << std::endl;
                    else
                        std::cout << fmt("Child Process: %d", childPid) << std::endl;
                }
            }
        }
        return numChildren;
    }

    void run(ref<Store> store) override
    {
        if (auto store2 = store.dynamic_pointer_cast<LocalFSStore>()) {
            auto userPoolDir = store2->stateDir + "/userpool";

            struct stat st;
            stat(userPoolDir.c_str(), &st);
            if (st.st_uid != geteuid() && geteuid() != 0)
                throw Error("you don't have permissions to see the userpool locks");

            auto dirs = readDirectory(userPoolDir);
            for (auto i = dirs.begin(); i != dirs.end(); i++) {
                int uid;
                try {
                    uid = std::stoi(i->name);
                } catch (const std::invalid_argument& e) {
                    continue;
                }
                auto uidPath = fmt("%s/%d", userPoolDir, uid);

                // try to lock it ourselves
                int fd = open(uidPath.c_str(), O_CLOEXEC | O_RDWR, 0600);
                if (lockFile(fd, ltWrite, false)) {
                    close(fd);
                    continue;
                }
                close(fd);

                int pid = fuser(uidPath);

                if (pid == -1)
                    continue;

                if (i != dirs.begin())
                    std::cout << std::endl;

                struct passwd * pw = getpwuid(uid);
                if (!pw)
                    throw Error("can't find uid for '%d'", uid);
                std::cout << fmt("Build User: %s", pw->pw_name) << std::endl;

                if (auto cmdline = getCmdline(pid))
                    std::cout << fmt("Build Process: %s", *cmdline) << std::endl;
                else
                    std::cout << fmt("Build Process: %d", pid) << std::endl;

                printChildren(pid);

                auto openFds = fmt("/proc/%d/fd", pid);
                if (pathExists(openFds))
                    for (auto & entry : readDirectory(openFds)) {
                        Path path;
                        try {
                            path = readLink(fmt("/proc/%d/fd/%s", pid, entry.name));
                        } catch (const Error & e) {
                            continue;
                        }
                        if (hasSuffix(path, ".lock"))
                            std::cout << fmt("File Lock: %s", path) << std::endl;
                    }
            }
        } else
            throw Error("must provide local store for nix process, found '%s'", store->getUri());
    }
};

static auto r1 = registerCommand<CmdProcesses>("processes");
