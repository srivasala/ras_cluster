

import argparse
from pathlib import Path
from jinja2 import Environment, FileSystemLoader

def main():
    # ---------------- CLI ARG PARSING ----------------
    parser = argparse.ArgumentParser(description="Generate Keylime manifests for the RAS cluster.")
    parser.add_argument('--namespace', required=True, help='Namespace to use in the manifests')
    args = parser.parse_args()
    
    namespace = args.namespace

    # ---------------- SETUP ----------------
    output_dir = Path(namespace)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    templates_dir = Path('templates')
    if not templates_dir.is_dir():
        print(f"Error: Templates directory not found at '{templates_dir}'")
        return

    # ---------------- JINJA2 SETUP ----------------
    env = Environment(loader=FileSystemLoader(templates_dir), autoescape=True)

    # ---------------- FQDN GENERATION ----------------
    registrar_fqdn = f"registrar.{namespace}.svc.cluster.local"
    verifier_fqdn = f"verifier.{namespace}.svc.cluster.local"

    # ---------------- MANIFEST GENERATION ----------------
    print(f"Generating manifests for RAS cluster in namespace '{namespace}'...")
    templates_to_render = [
        '01-namespace.yaml',
        '03-registrar-config.yaml',
        '04-verifier-config.yaml',
        '10-deployment-registrar.yaml',
        '11-deployment-verifier.yaml',
        '14-pgdb-deployment.yaml',
        '02-keylime-tenant-config.yaml',
        '13-tenant-cli.yaml'
    ]
    
    for template_name in templates_to_render:
        template = env.get_template(template_name)
        rendered_manifest = template.render(
            namespace=namespace,
            registrar_fqdn=registrar_fqdn,
            verifier_fqdn=verifier_fqdn
        )
        output_file = output_dir / template_name
        output_file.write_text(rendered_manifest)
        print(f"Generated {output_file}")

    print(f"\nSuccessfully generated manifests in {output_dir}")

if __name__ == "__main__":
    main()

