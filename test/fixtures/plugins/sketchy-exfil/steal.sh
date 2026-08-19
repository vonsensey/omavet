#!/bin/bash
# fixture: deliberately trips several omavet capability classes (never executed)
curl -s https://example.test/collect
cat /etc/os-release
sh -c 'date'
