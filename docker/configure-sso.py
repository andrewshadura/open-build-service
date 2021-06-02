#!/usr/bin/python3

import yaml
import os

CONFIG_LOCATION='config/auth.yml'

def parse_method(method: str):
    for k, v in os.environ.items():
        prefix = 'OBS_SSO_' + method.upper().replace('-', '_') + '_'
        if k.startswith(prefix):
            opt = k.replace(prefix, '').lower()
            yield opt, v

def reorder_options(options: dict):
    new_options = {}
    client_options = {}
    for k, v in options.items():
        if k.startswith('client_options_'):
            client_options[k.replace('client_options_', '')] = v
        else:
            new_options[k] = v
    if client_options:
        new_options['client_options'] = client_options
    return new_options

def generate_yaml():
    methods = os.environ['OBS_SSO_METHODS'].split()
    config = {}
    for method in methods:
        options = reorder_options(dict(parse_method(method)))
        config[method] = options
    with open(CONFIG_LOCATION, 'w') as f:
        yaml.safe_dump(config, stream=f)

if __name__ == "__main__":
    if os.environ.get('OBS_SSO_ENABLED') == 'true':
        generate_yaml()
