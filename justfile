# herdr federation — one node, one console, one socket.
#
# One module per concern. Reads are free; anything that changes who can reach
# this node, or that writes to another box, refuses without CONFIRM=yes and
# prints what it would have done first.
#
#   just                     modules and top-level recipes
#   just up                  build the console and run the node
#   just overview            the node and its federation, at a glance
#   just fed kick <node>     refuses, and shows you what it would remove
#   just tray install        the menu-bar app
#   just --list fed          one module's recipes

mod node   'just/01-node.just'
mod fed    'just/02-fed.just'
mod deploy 'just/03-deploy.just'
mod tray   'just/04-tray.just'

default:
    @just --list

# build, then run
up:
    @just node build
    @just node start

# the process and the federation in one screen
overview:
    @just node status
    @echo
    @just fed members
