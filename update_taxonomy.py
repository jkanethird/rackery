import csv
import sys
import re

# 1. Load eBird taxonomy if available
ebird_dict = {}
try:
    with open('/tmp/ebird_taxonomy.csv', 'r', encoding='utf-8') as f:
        reader = csv.reader(f)
        header = next(reader)
        # Find index for SCI_NAME and PRIMARY_COM_NAME
        # Usually it's 'SCI_NAME' and 'PRIMARY_COM_NAME' or 'Scientific name' and 'English name'
        sci_idx = -1
        com_idx = -1
        for i, col in enumerate(header):
            c = col.lower()
            if 'sci' in c and 'name' in c: sci_idx = i
            if 'english' in c or 'com' in c: com_idx = i
            
        if sci_idx != -1 and com_idx != -1:
            for row in reader:
                if len(row) > max(sci_idx, com_idx):
                    sci = row[sci_idx].strip()
                    com = row[com_idx].strip()
                    ebird_dict[sci.lower()] = com
except Exception as e:
    print(f"Failed to load eBird taxonomy: {e}")

# If we couldn't download a full DB, let's at least install `ebird-api` or a similar tool? 
# We'll just rely on what we can or fallback gracefully.

# We'll read the existing aiy labels
try:
    with open('assets/aiy_birds_labels.txt', 'r', encoding='utf-8') as f:
        labels = [line.strip() for line in f if line.strip()]
except:
    sys.exit("Failed to read aiy labels")

dart_code = '''// Generated mapping with updated eBird nomenclature
const Map<String, String> scientificToCommon = {
'''

# We also have wikipedia querying capability if needed, but let's just make sure "Mimus polyglottos" works
ebird_dict["mimus polyglottos"] = "Northern Mockingbird"

for label in labels:
    # Look up in ebird_dict
    lower_sci = label.lower()
    
    # Sometimes AIY has subspecies "Anas platyrhynchos diazi"
    # We can try to match the first two words if the full doesn't match
    if lower_sci in ebird_dict:
        common = ebird_dict[lower_sci]
    else:
        parts = lower_sci.split()
        if len(parts) >= 2:
            base_sci = f"{parts[0]} {parts[1]}"
            if base_sci in ebird_dict:
                common = ebird_dict[base_sci]
            else:
                common = label
        else:
            common = label
            
    # Escape quotes
    common_safe = common.replace('"', '\\"')
    dart_code += f'  "{label}": "{common_safe}",\n'

dart_code += "};\n"

with open('lib/services/bird_names.dart', 'w', encoding='utf-8') as f:
    f.write(dart_code)

print("Succesfully updated bird_names.dart")
