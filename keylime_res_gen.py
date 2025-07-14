
import zipfile
from pathlib import Path
import argparse
from jinja2 import Environment, FileSystemLoader

def main():
    # ---------------- CLI ARG PARSING ----------------
    parser = argparse.ArgumentParser(description="Generate Keylime manifests zip with custom namespace")
    parser.add_argument('--namespace', default='keylime-system', help='Namespace to use in the manifests (default: keylime-system)')
    args = parser.parse_args()
    namespace = args.namespace

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
    for template_file in sorted(templates_dir.glob('*.yaml')):
        template = env.get_template(template_file.name)
        rendered_manifest = template.render(namespace=namespace)
        
        output_file = output_dir / template_file.name
        output_file.write_text(rendered_manifest)
        manifests_to_zip.append(output_file)
        print(f"Generated {output_file}")

    # ---------------- ZIPPING ----------------
    zip_path = output_dir / "RAS-resourced-manifests.zip"
    with zipfile.ZipFile(zip_path, 'w') as zipf:
        for file_path in manifests_to_zip:
            zipf.write(file_path, arcname=file_path.name)
    
    print(f"\nSuccessfully created zip archive at {zip_path}")

if __name__ == "__main__":
    main()
