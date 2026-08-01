// Lógica para manejar el CRUD de sucursales con Supabase

document.addEventListener('DOMContentLoaded', cargarSucursales);

async function cargarSucursales() {
    const tabla = document.getElementById('tabla-sucursales');
    
    try {
        const { data: sucursales, error } = await supabase
            .from('sucursales')
            .select('*');

        if (error) throw error;

        if (!sucursales || sucursales.length === 0) {
            tabla.innerHTML = `<tr><td colspan="5" class="p-4 text-center text-gray-500">No hay sucursales registradas.</td></tr>`;
            return;
        }

        tabla.innerHTML = sucursales.map(s => `
            <tr class="border-b hover:bg-gray-50">
                <td class="p-4 font-medium text-gray-800">${s.nombre}</td>
                <td class="p-4 text-gray-600">${s.direccion || 'N/A'}</td>
                <td class="p-4 text-gray-600">${s.telefono || 'N/A'}</td>
                <td class="p-4">
                    <span class="px-2 py-1 text-xs font-semibold rounded-full ${s.activa !== false ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-800'}">
                        ${s.activa !== false ? 'Activa' : 'Inactiva'}
                    </span>
                </td>
                <td class="p-4 text-right space-x-2">
                    <button onclick="editarSucursal('${s.id}', '${s.nombre}', '${s.direccion || ''}', '${s.telefono || ''}')" class="text-blue-600 hover:text-blue-800">
                        <i class="fas fa-edit"></i>
                    </button>
                    <button onclick="eliminarSucursal('${s.id}')" class="text-red-600 hover:text-red-800">
                        <i class="fas fa-trash"></i>
                    </button>
                </td>
            </tr>
        `).join('');

    } catch (err) {
        console.error('Error al cargar sucursales:', err);
        tabla.innerHTML = `<tr><td colspan="5" class="p-4 text-center text-red-500">Error al cargar las sucursales. Verifica la consola.</td></tr>`;
    }
}

function abrirModal() {
    document.getElementById('form-sucursal').reset();
    document.getElementById('sucursal-id').value = '';
    document.getElementById('modal-titulo').innerText = 'Nueva Sucursal';
    document.getElementById('modal-sucursal').classList.remove('hidden');
}

function cerrarModal() {
    document.getElementById('modal-sucursal').classList.add('hidden');
}

async function guardarSucursal(e) {
    e.preventDefault();
    
    const id = document.getElementById('sucursal-id').value;
    const nombre = document.getElementById('nombre').value;
    const direccion = document.getElementById('direccion').value;
    const telefono = document.getElementById('telefono').value;

    try {
        if (id) {
            // Actualizar existente
            const { error } = await supabase
                .from('sucursales')
                .update({ nombre, direccion, telefono })
                .eq('id', id);
            if (error) throw error;
        } else {
            // Insertar nueva
            const { error } = await supabase
                .from('sucursales')
                .insert([{ nombre, direccion, telefono }]);
            if (error) throw error;
        }

        cerrarModal();
        cargarSucursales();
    } catch (err) {
        alert('Error al guardar la sucursal: ' + err.message);
    }
}

function editarSucursal(id, nombre, direccion, telefono) {
    document.getElementById('sucursal-id').value = id;
    document.getElementById('nombre').value = nombre;
    document.getElementById('direccion').value = direccion;
    document.getElementById('telefono').value = telefono;
    document.getElementById('modal-titulo').innerText = 'Editar Sucursal';
    document.getElementById('modal-sucursal').classList.remove('hidden');
}

async function eliminarSucursal(id) {
    if (!confirm('¿Estás seguro de eliminar esta sucursal?')) return;

    try {
        const { error } = await supabase
            .from('sucursales')
            .delete()
            .eq('id', id);

        if (error) throw error;
        cargarSucursales();
    } catch (err) {
        alert('Error al eliminar: ' + err.message);
    }
}
