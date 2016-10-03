# rapture

Rapture is a bash CLI tool for managing and switching between AWS IAM roles.


## Example

    $ rapture whoami
    arn:aws:iam::999988887777:user/janesmith

    $ rapture assume arn:aws:iam::000011110000:role/another-role
    rapture: Assumed 'another-role' in account 000011110000

    $ rapture whoami
    arn:aws:sts::000011110000:assumed-role/another-role/rapture-janesmith

    $ rapture resume
    rapture: Resumed user 'janesmith' in account 999988887777

    $ rapture whoami
    arn:aws:iam::999988887777:user/janesmith


## Prerequisites

* Bash 4 or later
* jq 1.5 or later


## Installation

The recommended way to install Rapture is to clone the Github repo directly to `~/.rapture`:

    $ git clone https://github.com/daveadams/rapture ~/.rapture

Then configure your shell to load Rapture at start:

    $ echo '[ -e ~/.rapture/rapture.sh ] && source ~/.rapture/rapture.sh' >> ~/.bash_profile

*NOTE:* You may need to add this line to `~/.bashrc` instead on some systems.

Finally, open a new terminal window to verify that Rapture is automatically loaded:

    $ rapture version
    Rapture 1.0.0


## Configuration

No configuration is required to start using Rapture, but Rapture will store configuration in `config.json`, `aliases.json`, and `accounts.json` in the `~/.rapture` directory.


## Caveats

Rapture assumes the use of `AWS_*` environment variables for determining the root identity.

Rapture does _not_ manage your secrets for you. I recommend [Vaulted](https://github.com/miquella/vaulted) for managing storing AWS access keys (and other secrets) securely in an easily manageable format and for loading them into your environment.
