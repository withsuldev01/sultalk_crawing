import csv

mapping = {
    '일반': '완료',
    '환불': '취소(환불)',
    '이월': '취소(이월)'
}

rows = []
file_path = '/Users/seungwookim/Code/withsullivan/sultalk_crawing/output/건강한소아청소년_2026_04.csv'

with open(file_path, 'r', encoding='utf-8') as f:
    reader = csv.reader(f)
    headers = next(reader)
    rows.append(headers)
    
    for i, row in enumerate(reader):
        # Some rows might have been truncated due to a previous awk mistake on quoted commas.
        # If they only have 7 columns, assume the 8th column was missing and we append '일반'
        # before we apply the mapping (since they were normal rows).
        if len(row) == 7:
            row.append('일반')
            
        if len(row) >= 8:
            status = row[7].strip()
            if status in mapping:
                row[7] = mapping[status]
                
        rows.append(row)

with open(file_path, 'w', encoding='utf-8', newline='') as f:
    writer = csv.writer(f)
    writer.writerows(rows)

print("Done")
