# Test Environment Proof of concept
Purpose of this repository is to prepare an environment to spinup servers similar to what we have in production and let us test our setup on them.

# Preparation
You need a recent installation of docker and docker-compose. You can find the instructions [here](https://www.docker.com/products/overview#/install_the_platform).

You need to be able to issue the following command to check if your installation is OK.

```bash
docker version
docker-compose version
```

# Test Environments
Each test environment is a set of servers which are responsible for a task or application. For example project-setup that is consisted of the following servers:

`s15 s16 s17 s46`

Each environment has its own directory. That directory will include a docker-compose.yml file that defies the set of servers. In this case there will be a directory team-dir/project-setup which will keep the file.

Structure of whole system will be similar to the following diagram:

```
.
├── compose
│   └── team-dir # different environments (set of server) for each team will be defined here.
│       └── project-setup # project name
│           ├── common.yml
│           └── docker-compose.yml # this file will define which server are involved for this task or project
└── servers # Dockerfiles which define initial setup of servers will be here
    ├── Dockerfil.debian.jessie.ssh # each type of server will have its own Dockerfile
    └── ssh
        ├── DUMMY_KEY_id_rsa # General key which will be installed on all servers.
        └── DUMMY_KEY_id_rsa.pub
```

To start an environment and all its servers you can simply do:

```bash
docker-compose -f compose/team-dir/project-setup/docker-compose.yml up -d
```

That command for example will start all 17 servers as docker containers.

To login to one of containers you can do
```bash
./login s15
# or
./login.sh ansible # in each env, this will be the server which will have access to all others to apply ansible setup
```

# Server setup
Now that servers are ready and running we need to apply our Ansible changes on them to have our complete setup.
