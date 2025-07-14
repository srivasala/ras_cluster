import zipfile
from pathlib import Path
import argparse
import uuid
from jinja2 import Environment, FileSystemLoader

def main():
    # ---------------- CLI ARG PARSING ----------------
    parser = argparse.ArgumentParser(description="Generate Keylime manifests with custom settings.")
    parser.add_argument('--namespace', help='Namespace to use in the manifests ')
    parser.add_argument('--agents', type=int, default=1, help='Number of agent pods to generate (default: 1)')
    args = parser.parse_args()
    
    namespace = args.namespace
    agent_count = args.agents

    # ---------------- SETUP ----------------
    output_dir = Path('artifacts')
    output_dir.mkdir(parents=True, exist_ok=True)
    
    templates_dir = Path('templates')
    if not templates_dir.is_dir():
        print(f"Error: Templates directory not found at '{templates_dir}'")
        return

    # ---------------- JINJA2 SETUP ----------------
    env = Environment(loader=FileSystemLoader(templates_dir), autoescape=True)

    # ---------------- MANIFEST GENERATION ----------------
    manifests_to_zip = []
    
    # Process all non-agent templates first
    for template_file in sorted(templates_dir.glob('*.yaml')):
        if 'agent' in template_file.name:
            continue # Skip agent templates for now
            
        template = env.get_template(template_file.name)
        rendered_manifest = template.render(namespace=namespace)
        
        output_file = output_dir / template_file.name
        output_file.write_text(rendered_manifest)
        manifests_to_zip.append(output_file)
        print(f"Generated {output_file}")

    # Process agent templates in a loop
    agent_config_template = env.get_template('05-agent-config.yaml')
    agent_pod_template = env.get_template('12-deployment-agent-swtpm.yaml')

    for i in range(1, agent_count + 1):
        agent_id = i
        agent_uuid = str(uuid.uuid4())
        
        # Render and write agent configmap
        rendered_config = agent_config_template.render(
            namespace=namespace, 
            agent_id=agent_id, 
            agent_uuid=agent_uuid
        )
        config_output_file = output_dir / f"05-agent-config-{agent_id}.yaml"
        config_output_file.write_text(rendered_config)
        manifests_to_zip.append(config_output_file)
        print(f"Generated {config_output_file}")

        # Render and write agent pod
        rendered_pod = agent_pod_template.render(
            namespace=namespace, 
            agent_id=agent_id
        )
        pod_output_file = output_dir / f"12-deployment-agent-swtpm-{agent_id}.yaml"
        pod_output_file.write_text(rendered_pod)
        manifests_to_zip.append(pod_output_file)
        print(f"Generated {pod_output_file}")

    # ---------------- ZIPPING ----------------
    zip_path = output_dir / "RAS-resourced-manifests.zip"
    with zipfile.ZipFile(zip_path, 'w') as zipf:
        for file_path in manifests_to_zip:
            zipf.write(file_path, arcname=file_path.name)
    
    print(f"\nSuccessfully created zip archive at {zip_path}")

if __name__ == "__main__":
    main()
